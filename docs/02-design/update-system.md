# Update System

This document covers **Android application updates**: when APKRun checks for new versions, where it finds them, how it validates them, when it installs them, and what happens when a new version does not work. The store mechanics it relies on (the journal, artifact slots, install sessions, rollback per image kind) are in [package-store.md](package-store.md).

APKRun has four independent update systems. They never share code paths or state:

| Update | What changes | Where it is designed |
|---|---|---|
| Android application | an APK set inside Android | this document |
| APKRun runtime | APKRun.app, apkrund, the CLI (Sparkle) | [runtime-maintenance.md](runtime-maintenance.md) |
| Android guest image | the runtime image bundle (AOSP, kernel, Mesa) | [android-image.md](android-image.md) §12, [runtime-maintenance.md](runtime-maintenance.md) |
| Wrapper metadata | a wrapper's name, icon, URL handling, window preferences | [wrapper.md](wrapper.md). An APK update never changes a wrapper (FR-WRP-04) |

---

## 1. Responsibilities

| Component (UpdateCore) | Responsibility |
|---|---|
| `UpdateScheduler` (actor) | decides when each package is checked (§3). Runs in apkrund |
| `ProviderRegistry` | maps `UpdateProviderRef.type` to a provider and validates provider configuration (§4) |
| `UpdateCoordinator` (actor) | owns `UpdatePhase` per package ([state-machines.md](../01-architecture/state-machines.md) §6). Drives check → download → validate → stage → install → health check → rollback |
| `UpdateValidator` | the relational checks V1–V6 on top of the store's intrinsic checks (§6) |
| `GentleUpdateGate` | decides when a staged update may be installed (§7) |
| `UpdateHealthChecker` | the post-update health check (§8) |
| `UpdateStateStore` | `Updates/state.json` and `Updates/history.jsonl` (§10) |

UpdateCore depends only on APKStoreCore, RuntimeAPI, and DiagnosticsCore ([modules.md](../01-architecture/modules.md) §3). It never talks to Android directly. Installs, rollbacks, and ownership changes are store operations ([package-store.md](package-store.md) §7). It reaches sessions, displays, and the Guest Agent through `UpdateRuntimeAccess` (§7.5), which RuntimeHost injects.

---

## 2. Authority and update mode

### 2.1 Authority

Each package has exactly one update authority (FR-UPD-01, ADR-0010). It is stored in the package record (`updateAuthority`, [package-store.md](package-store.md) §2.3).

| Authority | Who updates | APKRun checks providers | APKRun installs updates | Update ownership in Android |
|---|---|---|---|---|
| `apkrun` | APKRun, from the attached provider | yes | yes, per the update mode (§2.2) | claimed (`io.apkrun.store`) |
| `manual` | the user, by supplying a newer APK | no | only user-supplied files | claimed |
| `googlePlay` | Google Play (post-v1, #097) | no | no | not claimed |
| `external` | another installer in Android (adopted packages, [package-store.md](package-store.md) §9.3) | no | no. A user-supplied file asks to switch to `manual` first | not claimed |

Rules:

- A provider attaches only to an `apkrun` package. Attaching one to a `manual` package makes it `apkrun`. Detaching the provider makes it `manual`.
- Only changes to and from `googlePlay` and `external` touch Android. The store calls `RelinquishUpdateOwnership` when a package leaves `apkrun` or `manual` ([package-store.md](package-store.md) §6.3).
- APKRun never installs an update for a `googlePlay` or `external` package in the background. Two automatic updaters never manage the same package.
- The user changes the authority with `setUpdateAuthority(id, AuthorityChoice)` (§11.1): **Updated by** in the app's settings ([host-ui.md](host-ui.md) §7.5) and `apkrun update authority` (§11.3). The choices are `apkrun`, `manual`, and `external`. Only #097 sets `googlePlay`, and a `googlePlay` package refuses every change (`update.authorityDoesNotAllowUpdates`). Changing to `apkrun` requires a provider in the record, or the call fails with `update.providerNotConfigured`. The change goes through `PackageStore.setUpdateAuthority`.
- An authority change holds the package's operation lock, so it waits for a running install. An update of the package that has not started its install ends as `skipped(.authorityChanged)`. A staged set that the new authority does not install is discarded. That is a provider update when the package leaves `apkrun`, and every staged set when the package moves to `external`.

### 2.2 Update mode

The update mode applies only to `apkrun` packages. It is stored in `settings.json` as `update.mode` ([package-metadata-json.md](../03-reference/package-metadata-json.md) §3).

| `update.mode` | Behavior |
|---|---|
| `automatic` (default) | check → download → validate → stage → gentle install → health check, without asking |
| `notifyOnly` | check. When a newer version exists, stop in `available` and notify. Download and install start when the user chooses "Update" |

### 2.3 What the UI shows

| UI choice ("Updates") | Authority | `update.mode` | Provider |
|---|---|---|---|
| Automatic | `apkrun` | `automatic` | required. Without one, the choice is disabled with "Choose where updates come from" |
| Notify only | `apkrun` | `notifyOnly` | required |
| Manual | `manual` | kept but unused | kept but unused, so switching back restores it |
| (read-only) "Managed by Google Play" / "Managed by another installer" | `googlePlay` / `external` | — | — |

`setUpdatePolicy` refuses every choice for a `googlePlay` or `external` package with `update.authorityDoesNotAllowUpdates`.

`setUpdatePolicy(id, UpdatePolicy{choice, provider})` (§11.1) writes the mode, the authority, and the provider under the package's operation lock, without a journal transaction. It writes `settings.json` `update.mode` first, then `updateAuthority` and `updateProvider` in the record. A crash between the two writes never turns on automatic updates, because the mode has no effect without the authority `apkrun` ([package-metadata-json.md](../03-reference/package-metadata-json.md) §6.2).

### 2.4 Defaults at install

| How the package arrived | Authority | Mode | Provider |
|---|---|---|---|
| File import, no provider chosen | `manual` | `automatic` (unused until a provider is attached) | none |
| File import, provider chosen or detected in the Add sheet (§4.7) | `apkrun` | `automatic` | the chosen provider |
| `apkrun install … --provider <spec>` | `apkrun` | `automatic`, unless `--updates notify` | from the spec (§11.3) |
| Portable wrapper bootstrap | from `wrapper.json` `updates.authority`, `updates.mode`, and `updates.provider` when present | same | same. These are initial values only. Later changes live in the package settings, never in the wrapper (#089) |
| Adopted package | `external` | — | none |

---

## 3. Scheduling

### 3.1 Principles

- **Launch never waits for an update check** (FR-UPD-08, NFR-PERF-07). `openSession` does not call UpdateCore on its path. It notifies UpdateCore after it replies ([runtime-daemon.md](runtime-daemon.md) §7.1).
- Checks, downloads, validation, and staging are host-only. They never boot, resume, or wake Android, and they are not runtime activity ([runtime-daemon.md](runtime-daemon.md) §5.1).
- Only installs and health checks need Android. They run when the runtime is already running (§7), or when the user asks for an update.

### 3.2 When a package is due

`nextCheckAt = lastCheckAt + interval ± jitter`:

- `interval` is the global setting `updates.checkIntervalHours`. The default is **6**. Allowed values: 1, 3, 6, 12, 24, 72, 168.
- `jitter` is uniformly random within ±10 % of the interval, fixed per package per cycle. It spreads requests to the same provider host.
- After a failed check, the next attempt uses backoff: 30 min, then 2 h, then the normal interval. A rate-limit response uses the provider's `Retry-After` or reset time, if that is later (§4).
- A package is not checked in `downloading`, `validating`, `installing`, `healthChecking`, or `rollingBack`. A `staged` package is still checked on schedule. A newer candidate that passes validation replaces the staged one (`stage` replaces `staged/`, [package-store.md](package-store.md) §5.2), and its waiting time (§7.4) starts again.
- A package with no `lastCheckAt`, for example one whose provider was just attached, is due now.
- Packages whose authority is not `apkrun` are never due.

### 3.3 Triggers

| Trigger | What happens |
|---|---|
| apkrund starts (login `RunAtLoad`, a client connection, the hourly `StartInterval` wake) | the scheduler runs every due check. If nothing else keeps apkrund alive, it exits after the work is done ([runtime-daemon.md](runtime-daemon.md) §2.4) |
| Timer while apkrund runs | sleep until the earliest `nextCheckAt` (`ContinuousClock`, so checks that became due during sleep run after wake) |
| Mac wakes from sleep | due checks run after a 2-minute delay, so networking is up and wake-time work is not all at once |
| A session for the package opens (`noteLaunched`) | if the package is due, check it 30 s after the first frame, at `utility` priority ("background update check") |
| The user chooses "Check for updates" (Home, menu bar, `apkrun update`) | check the chosen packages now, ignoring `nextCheckAt` and backoff. User-initiated checks run before background checks |

### 3.4 Resource rules

- At most 4 checks in parallel, and at most 2 per provider host. At most one background download at a time. User-initiated downloads do not wait for it.
- Network: `NWPathMonitor`. When the path is unsatisfied, due checks wait for a satisfied path. On an expensive path (for example a personal hotspot) or a constrained one (Low Data Mode), checks still run, but **background downloads wait** unless `updates.downloadOnExpensiveNetwork` is on. User-initiated downloads always run.
- Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`): background downloads larger than 50 MiB wait.
- All requests use one `URLSession`: `waitsForConnectivity = true`, a 30 s request timeout, the system proxy, HTTP/2, and at most 4 connections per host. ATS applies: HTTPS only (§12).

### 3.5 Background install without a running runtime

A staged update waits until the runtime runs for another reason (§7.1). One exception: `updates.startRuntimeToInstall` (default **off**). When an update has waited more than 24 h, the Mac is on AC power, and the user has been idle for at least 15 minutes (`HIDIdleTime`), apkrund boots the runtime headless. It installs and health-checks every staged update whose gate is open. The idle policy then stops the runtime again.

---

## 4. Providers

### 4.1 Protocol

Each provider implements this protocol and receives the context it needs:

```swift
public protocol UpdateProvider: Sendable {
    var ref: UpdateProviderRef { get }

    /// Returns a candidate that may be newer than `package`, or nil. Must not download APKs.
    /// The final decision is UpdateValidator's, made on the downloaded APKs (FR-UPD-14).
    func check(_ package: InstalledPackage, context: ProviderContext) async throws(UpdateFailure) -> UpdateCandidate?

    /// Downloads every artifact of the candidate into `destination` (Packages/<id>/incoming/<ticket>/),
    /// hashing while streaming.
    func download(_ candidate: UpdateCandidate, to destination: DownloadDestination,
                  context: ProviderContext,
                  progress: @Sendable (DownloadProgress) -> Void) async throws(UpdateFailure) -> PackageArtifact
}

public struct UpdateProviderRef: Codable, Sendable, Hashable {
    public var type: ProviderType              // .local, .direct, .fdroid, .github
    public var configuration: ProviderConfiguration   // typed per provider, stored as JSON (package-metadata-json.md §2.4)
}

public struct InstalledPackage: Sendable {
    public var id: PackageID
    public var versionCode: VersionCode
    public var signerDigests: [SHA256Digest]
    public var lineage: [SHA256Digest]
    public var guest: GuestFacts               // SDK, ABIs
    public var lastCursor: ProviderCursor?     // what the provider saw last time (§4.2)
}

public struct UpdateCandidate: Codable, Sendable, Hashable {
    public var packageID: PackageID
    public var provider: UpdateProviderRef
    public var declaredVersionCode: VersionCode?        // nil when unknown before download (GitHub)
    public var declaredVersionName: String?
    public var declaredSignerDigests: [SHA256Digest]?   // F-Droid index, Direct manifest (optional)
    public var artifacts: [RemoteArtifact]
    public var releaseNotes: String?                    // plain text, at most 16 KiB, shown as text (never HTML)
    public var publishedAt: Date?
    public var cursor: ProviderCursor                   // identifies this release to the provider
}

public struct RemoteArtifact: Codable, Sendable, Hashable {
    public var url: URL                                 // HTTPS (file URL for LocalProvider)
    public var kind: RemoteArtifactKind                 // .apk, .split(name:), .container (.apks, .xapk, .apkm)
    public var sha256: SHA256Digest?                    // provider-declared; required for Direct and F-Droid
    public var size: Int64?
}

public struct ProviderContext: Sendable {
    public var http: UpdateHTTPClient                   // the shared session of §3.4
    public var cache: ProviderCache                     // Providers/cache/<type>/<key>/
    public var credentials: ProviderCredentials         // Keychain access (GitHub token)
    public var userInitiated: Bool
}
```

`PackageArtifact` is the store's type ([package-store.md](package-store.md) §2.2). A container download (`.apks`, `.xapk`, `.apkm`) goes through the same extraction and split selection as a file import. The container type comes from the content ([package-store.md](package-store.md) §4.2). Direct manifests allow only `.apks` ([direct-provider-manifest.md](../03-reference/direct-provider-manifest.md) §4). GitHub and Local artifacts may be any container of [package-store.md](package-store.md) §4.2. A GitHub asset whose name does not end in `.apk`, `.apks`, `.xapk`, or `.apkm` is not a candidate.

### 4.2 Cursors

A `ProviderCursor` is opaque and provider-defined: an ETag, a release ID plus asset digest, or an index timestamp. UpdateCore saves the cursor of every candidate it processes, whatever the outcome (updated, not newer, validation failed, skipped). A provider returns nil when the current release matches the saved cursor. That keeps checks cheap, and it stops APKRun from downloading a file it already knows is unusable.

### 4.3 LocalProvider

For tests and development. It is hidden in the UI unless developer mode is on. The CLI form is `--provider local:<path>`.

```text
<root>/
└── <packageId>/
    ├── 1/
    │   └── app.apk                      # or base.apk + split_*.apk, or one .apks
    └── 2/
        └── app.apk
```

- `check`: the highest numeric directory name greater than the installed versionCode is the candidate. `declaredVersionCode` is the directory name. The cursor is the directory name plus its modification time. A directory `0` is never a candidate.
- `download`: `clonefile` or copy into the ticket directory.
- The provider has no hashes. Every other check applies.

### 4.4 DirectProvider

A distributor publishes an APKRun manifest over HTTPS (FR-UPD-12). The format is in [direct-provider-manifest.md](../03-reference/direct-provider-manifest.md).

- Configuration: `{url}`. The URL must be HTTPS. Debug builds also accept `http://127.0.0.1` and `http://localhost`, for the local test service (#050).
- `check`: GET with `If-None-Match` and `If-Modified-Since`. `304` → nil. The manifest must be at most 1 MiB of valid JSON that matches the schema, and its `packageId` must equal the package. `versionCode ≤` installed → nil. Cursor = the ETag, or the SHA-256 of the body.
- Artifact URLs may be relative (resolved against the manifest URL). They must be HTTPS after resolution. Every artifact needs `sha256`. A split uses `"type": "split"` with `"splitName"`. A container uses `"type": "apks"`.
- Redirects are followed only to HTTPS URLs, at most 5.
- The published JSON Schema is `docs/03-reference/schemas/direct-provider-manifest.schema.json`. The Codable model and the semantic checks live in UpdateCore, and the schema is checked against the model's T0 fixtures.
- Signed manifests are a v1.x candidate (OQ-19). The APK signer check (V3, §6) protects the update. The manifest hash protects against corrupted or swapped downloads.

### 4.5 F-Droid provider

Uses F-Droid's signed repository index, v2 (FR-UPD-13). Field names must be verified against the F-Droid index documentation (#051, OQ-18).

- Configuration: `{repository, fingerprint}`. The default is the main repository `https://f-droid.org/repo`, with the signing-certificate fingerprint `43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab` pinned in the app (verify in #051). Other repositories need their own fingerprint, as in F-Droid's `?fingerprint=` links.
- **Index verification.** Download `entry.jar` and read it with ZIPFoundation (ADR-0017). At most 16 entries and 16 MiB in total. Anything else is `providerMetadataInvalid`. Verify the JAR signature: the CMS signature over `META-INF/*.SF` with `CMSDecoder`, the signer certificate's SHA-256 against the pinned fingerprint, the `.SF` digests of `MANIFEST.MF`, and the manifest digest of `entry.json`. A failure is `providerSignatureInvalid`. It is a health error, and the repository provides no update.
- `entry.json` names the full index (`index-v2.json`) and diffs, each with a SHA-256. The provider downloads the diff from its cached timestamp when one exists. Otherwise it downloads the full index, checks the SHA-256, and merges. Cache: `Providers/cache/fdroid/<first 16 hex of SHA-256(repository)>/`. The index refreshes at most once per check interval, for all packages together.
- The index is decoded with a streaming JSON reader that keeps only the packages APKRun manages or is asked about. Memory budget: 64 MiB.
- `check`: among `packages[<id>].versions`, the candidate is the highest `manifest.versionCode` that is greater than installed, whose `manifest.nativecode` is empty or contains a guest ABI, whose `manifest.usesSdk.minSdkVersion ≤` guest SDK, and whose `manifest.signer.sha256` equals the installed signer set. The artifact is `<repository>/<file.name>` with `file.sha256` and `file.size`. Cursor = index timestamp + chosen version hash.
- **Signer mismatch.** F-Droid usually signs its own builds, so an APK from the developer often has another signer. When versions exist but none has the installed signer, `check` returns nil and records `noCompatibleArtifact(.signerDiffers)`. The package settings say: "F-Droid's builds of ‹App› are signed by F-Droid, not by the developer of the installed copy. To use F-Droid updates, uninstall ‹App› and install it from F-Droid." APKRun never installs across signers.

### 4.6 GitHub provider

For apps published as GitHub release assets (FR-UPD-13).

- Configuration: `{repository: "owner/name", assetPattern: "*.apk", channel: "stable" | "prerelease"}`. An optional personal access token is stored in the Keychain (service `io.apkrun.provider.github`). It is never stored in `settings.json` or logged.
- `check`: `GET https://api.github.com/repos/{owner}/{name}/releases?per_page=10` with `Accept: application/vnd.github+json`, `X-GitHub-Api-Version`, and `If-None-Match`. The chosen release is the newest non-draft release. Pre-releases count only on the `prerelease` channel. The asset is the one whose name matches `assetPattern` (glob). If several match, prefer names containing `arm64-v8a` or `arm64`, then `universal`. If several still match, fail with `ambiguousAsset(names)` so the user can narrow the pattern.
- The tag and release name are **not** versions. `declaredVersionCode` is nil. The candidate is downloaded and inspected, and V2 (§6) decides.
- Hash: the asset's `digest` (`sha256:…`) when the API provides it (verify in #052, OQ-18). Otherwise the download is protected only by TLS, and the history entry says "No checksum published".
- Cursor = release ID + asset ID + asset `updated_at` + size. The cursor prevents a second download of a non-newer asset.
- Rate limits: `403` or `429` with `x-ratelimit-remaining: 0` → `providerRateLimited(retryAfter: x-ratelimit-reset)`. `304` responses are cheap. Unauthenticated use (60 requests per hour per IP) is enough at the default interval for dozens of packages.

### 4.7 Provider detection in the Add sheet

When a package is imported without a provider, the Add sheet (#078) may suggest one:

- F-Droid: the package ID is in the cached main-repository index **and** a version there has the imported signer.
- Direct: the portable wrapper or the `apkrun install --provider` spec supplies one.
- GitHub is never guessed.

The suggestion is off by default. The user turns it on, and the sheet shows where the updates will come from.

---

## 5. From candidate to staged update

```text
UpdateCoordinator.run(package)
  checking        provider.check → nil → completed(.skipped(.upToDate)); cursor saved
                  error → completed(.skipped(.checkFailed(UpdateFailure))); backoff (§3.2)
                  → candidate → available(candidate)
  available       notifyOnly: stop, notify (§9). automatic, or the user chose "Update": continue
  downloading     PackageStore.beginDownloadTicket(id) → incoming/<ticket>/
                  provider.download (hash while streaming; size cap 8 GiB; progress events)
                  sha256 ≠ declared → discard, retry once from scratch, then .hashMismatch
  validating      PackageStore.inspect(ticket) → intrinsic checks (package-store.md §4.6)
                  UpdateValidator V1–V6 (§6)
                  failure → completed(.skipped(.validationFailed(reason))); ticket deleted; cursor saved
  staged          PackageStore.stage(ticket, StagedUpdateInfo{provider, candidate, validation report})
                  → GentleUpdateGate (§7)
```

- A **manual update** (a newer file the user imports, `ImportRelation.update`, [package-store.md](package-store.md) §4.7) enters at `validating` with the import ticket. It then follows the same path. Its gate is user-initiated (§7.3).
- A download that fails with a network error retries twice with backoff (10 s, then 60 s) in the same run. Then it ends with `completed(.skipped(.downloadFailed))`, and the next check follows §3.2. A partial download is deleted. Resuming partial downloads is not in v1 (OQ-21).
- Every run appends one history entry (§10.2), whatever its outcome.
- `UpdateOutcome.skipped` reasons: `.upToDate`, `.checkFailed(UpdateFailure)`, `.downloadFailed(UpdateFailure)`, `.validationFailed(ValidationFailure)`, `.installFailed(StoreFailure)`, `.userSkipped`, `.authorityChanged`. All transitions are in [state-machines.md](../01-architecture/state-machines.md) §6.

---

## 6. Validation pipeline

Every update, from a provider or from a user's file, passes all of these checks before it can be staged (FR-UPD-04, [security-model.md](../01-architecture/security-model.md) §5). No check can be disabled, and no setting turns one off (NFR-SEC-04).

| # | Check | Input | Failure (`ValidationFailure`) |
|---|---|---|---|
| V0 | Intrinsic checks I1–I12 ([package-store.md](package-store.md) §4.6): container, one base, consistent splits, valid signature, required splits, ABI, min SDK, target SDK floor, not reserved, size, `resources.arsc` packaging | the downloaded set | `.intrinsic(StoreFailure)` |
| V1 | **Package ID** equals the installed package | APK manifest | `.packageMismatch(expected:found:)` |
| V2 | **versionCode** is greater than the installed `longVersionCode` (from Android, as recorded by the last reconcile). Equal is not newer. Lower is a downgrade, always refused (FR-UPD-05) | APK manifest | `.notNewer`, `.downgrade(installed:candidate:)` |
| V3 | **Signer continuity** (below) | APK signing block, installed record | `.signerMismatch`, `.lineageMissingCapability` |
| V4 | **Provider hash**: each file's SHA-256 equals the provider-declared digest, when one is declared (Direct and F-Droid always, GitHub when published). A download that differs while streaming fails earlier, in `downloading`, with `update.hashMismatch` (`UpdateFailure.hashMismatch`, §5). V4 hashes the stored files again, so it fails only for a file that changed after the download | download | `.providerHashMismatch(file)` |
| V5 | **Provider metadata agrees with the APK** where the provider declared it: package, versionCode, signer. The APK is the authority (FR-UPD-14). A disagreement means stale or tampered metadata, so the update is refused, not trusted | candidate vs. APK | `.providerMetadataMismatch(field)` |
| V6 | **Not skipped**: the versionCode is not in the package's `skippedVersions` (§8.4), unless the user chose it explicitly | update state | `.skippedVersion` |

**V3, signer continuity.** Let *S* be the installed signer set (from Android) and *S′* the candidate's signer set (from the host verifier, [package-store.md](package-store.md) §4.5).

1. If *S′ = S*: accept.
2. Else, if both sets have one signer and the candidate's lineage contains the installed signer with the `INSTALLED_DATA` capability (the rotation Android accepts for updates): accept. Record the rotation in the history.
3. Else, if the installed package's lineage contains the candidate's signer with `ROLLBACK` (a rotation being undone): accept.
4. Otherwise refuse. Multiple-signer sets never rotate. They must be equal.

Android's `PackageManager` enforces the same rule. APKRun checks it first, so it never stages an update that Android would refuse, and it can explain why ([security-model.md](../01-architecture/security-model.md) §5). If the host verifier only reaches the `.certificateOnly` level, V3 compares certificate digests, and Android remains the final check.

The result is a `ValidationReport` (each check with its inputs and verdict). It is saved with the staged set (`staged/validation.json`, [package-store.md](package-store.md) §3.1) and shown under "Details" in the update history. The report also records, without blocking, newly requested permissions (compared with the installed version's `requested_permissions_count` and the host inspector's list), a target SDK change, and a size change above 50 %.

---

## 7. Gentle updates

An update is never installed while the app is in use (FR-UPD-07). "In use" means the same thing on every image, and the outcome is deterministic.

### 7.1 Conditions

`GentleUpdateGate.isOpen(package)` is true when **all** of these hold:

| # | Condition | Source |
|---|---|---|
| GU1 | The runtime is `ready`. A `suspended` runtime counts only for user-initiated updates, which resume it. A `stopped` runtime never opens the gate by itself (§3.5 is the only exception) | `RuntimeSupervisor` |
| GU2 | No `AppSession` for the package in any state except `ended`, including `backgrounded` | `SessionRegistry` ([runtime-daemon.md](runtime-daemon.md) §7) |
| GU3 | No keep-running task for the package (`window.closeBehavior = keepRunning`) | `ActivityKind.backgroundTask` ([runtime-daemon.md](runtime-daemon.md) §5.1) |
| GU4 | The last session of the package ended at least 15 s ago | `SessionRegistry` |
| GU5 | Android agrees. Custom image: `CheckInstallConstraints` (Store Agent op 110) with `InstallConstraints.GENTLE_UPDATE` plus `setAppNotForegroundRequired()`, 10 s timeout. Stock image: the Guest Agent's `ListTasks` shows no task of the package on any display | [guest-protocol.md](guest-protocol.md) §11.1 |
| GU6 | No other store transaction for the package is running or queued ahead of it (one Android commit at a time, [package-store.md](package-store.md) §5.3) | `PackageStore` |
| GU7 | A DisplayPool slot is free for the health check (§8), unless the health check level is `versionOnly` | `DisplayPool` |

GU5 is a hint. Its answer can change a moment later. The deterministic part is on the host: GU2–GU4, plus the rule in §7.2 that a session opened during an install waits for it.

Whether `GENTLE_UPDATE` with `setAppNotForegroundRequired()` treats a foreground service as "in use" is open (OQ-17). If it does not, custom-image GU5 adds the `ListTasks` rule and a process-importance query.

### 7.2 Evaluation and races

- The gate is evaluated when an update is staged, when a session of the package ends (after GU4's 15 s), when a keep-running task ends, when the runtime becomes `ready`, and every 10 minutes while updates are staged and the runtime is ready.
- When the gate opens, the coordinator calls `PackageStore.installStaged(id, enableRollback: true)`. That runs the `update` transaction ([package-store.md](package-store.md) §7.2) under a `storeOperation` assertion, so the idle policy cannot suspend the runtime mid-install.
- **A session requested during an install:**
  - Before the Android commit was requested (files still streaming): the install is cancelled (`AbandonInstall`). The update returns to `staged`, and the session opens at once with the old version.
  - After the commit was requested: the session waits for the transaction, up to 30 s, with the placeholder "Updating ‹App›…". Then it launches the new version ([runtime-daemon.md](runtime-daemon.md) §7.1). The session's first frame counts as H4 (§8.1), in place of the health-check launch.
- One package installs at a time. When several are staged, the order is user-initiated first, then the package whose update has waited longest.

### 7.3 User-initiated updates

"Update Now" (Home, notification action, `apkrun update <package>`, and every manual update from a file):

- If the runtime is stopped, it starts. The user asked for the update.
- If the app is open, APKRun asks "Quit ‹App› and update now?" with **Update Now** and **When ‹App› Quits**.
  - **Update Now** (`UpdateNowOptions.closeRunningApp = true`) ends the session with reason `.updating` (the wrapper closes its window), installs the update, and reopens the app after a successful update. `apkrun update <package> --now` is **Update Now** without the question.
  - **When ‹App› Quits** (`closeRunningApp = false`) leaves the operation waiting in apkrund. Its waiting reasons are the gate conditions that are false. It installs when the gate opens. Without `--now`, `apkrun update <package>` prints "will update when ‹App› quits" and returns. A closed client connection does not cancel the operation ([runtime-api.md](../03-reference/runtime-api.md) §4.7). Only a cancel ends the wait.
- If the app is opened again before the Android commit was requested, §7.2 applies to user-initiated installs too. The install is cancelled, the update returns to `staged`, and the operation waits as for **When ‹App› Quits**. Launch is never blocked ([../../AGENTS.md](../../AGENTS.md) §4, invariant 9). After the commit was requested, the session waits as in §7.2.
- GU5 is not required for user-initiated updates. GU2 and GU3 become true when the session ends.

### 7.4 Waiting too long

When an update has been staged for 7 days without the gate opening (the app is always open, or the runtime never runs), APKRun posts one notification: "‹App› ‹version› is ready to install. Quit ‹App› to update." It offers **Update Now**. It never closes an app on its own.

### 7.5 Runtime access

```swift
/// Injected by RuntimeHost. UpdateCore never imports RuntimeCore.
public protocol UpdateRuntimeAccess: Sendable {
    var runtimeState: RuntimeState { get async }
    var runtimeEvents: AsyncStream<RuntimeEvent> { get }                 // state changes, session starts/ends, task ends
    func hasActiveUse(_ package: PackageID) async -> Bool                // GU2 + GU3
    func lastSessionEnd(_ package: PackageID) async -> ContinuousClock.Instant?
    func androidAllowsGentleInstall(_ package: PackageID) async -> Bool  // GU5 on either image
    func ensureReady(_ reason: StartReason) async throws(RuntimeFailure)          // .update (§3.5, §7.3)
    func endSessions(for package: PackageID, reason: SessionEndReason) async
    func reopen(_ package: PackageID) async                              // after "Update Now"
    func healthCheckLaunch(_ package: PackageID, timeouts: HealthCheckTimeouts) async -> HealthLaunchResult   // §8.2
}
```

---

## 8. Health check and rollback

### 8.1 Steps

After every update install (automatic, user-initiated, or manual), `UpdateHealthChecker` confirms that the new version works (FR-UPD-10):

| # | Step | Pass | Timeout |
|---|---|---|---|
| H1 | Android reports the new version | `GetPackageMetadata` (or `QueryPackage`) returns the staged versionCode and signer set | 30 s |
| H2 | Launch | `LaunchApplication` of the package's launcher activity on a health-check display succeeds | 20 s |
| H3 | Process alive | the app's process exists 5 s after launch, and has not crashed or hit an ANR by 15 s (`AppProcessEvent`) | 15 s |
| H4 | First frame | the health-check display receives a frame after the launch | 20 s after H2 |

Levels:

- `full` (H1–H4): the default for packages with a launcher activity.
- `processOnly` (H1–H3): used when H4 cannot be meaningful. That is, when the app has never produced a first frame in APKRun: no `FIRST_FRAME` marker in its session history, and no earlier passing H4.
- `versionOnly` (H1): for packages without a launcher activity, and for packages whose `update.healthCheckLaunch` is off.

The total budget is 90 s. The level used is recorded in the history.

### 8.2 The health-check launch

- RuntimeHost acquires a DisplayPool lease for a system session (`SessionID.system(.updateHealthCheck(package))`, [display-and-windowing.md](display-and-windowing.md) §3.1). The geometry comes from the package's settings, or the default 480 × 850 pt of [display-and-windowing.md](display-and-windowing.md) §6.2, at backing scale 2. The display has no window and no client. Frames go to its surfaces and are counted, not shown.
- The app launches on that display with the same path as a session ([runtime-daemon.md](runtime-daemon.md) §7.1 steps 5–7).
- Afterwards the lease is released. DisplayPool clears the display, which removes the app's task ([display-and-windowing.md](display-and-windowing.md) §3.4). The app is **not** force-stopped, so it does not enter Android's stopped state, and its alarms and jobs stay scheduled.
- The health-check display gets no input and no clipboard sync. Notifications the app posts are forwarded as usual.
- When a user session opens during the health check, the health-check launch is abandoned, and the session's own launch is used for H2–H4.

### 8.3 Outcomes

| Result | Next |
|---|---|
| Pass | `completed(.updated(from:to:))`. `previous/` stays until the next successful update. Optional notification (§9) |
| Fail, `update.autoRollback` on (default) | `rollingBack(.healthCheckFailed(reason))` → `PackageStore.rollback(id, reason)` ([package-store.md](package-store.md) §7.3) |
| Fail, `update.autoRollback` off | `completed(.keptAfterFailedHealthCheck(reason))`, with a notification and **Roll Back** |

Rollback results:

| Store result | Phase | User sees |
|---|---|---|
| rolled back (RollbackManager on custom images, downgrade reinstall on debuggable images) | `completed(.rolledBack(reason))` | The app did not start correctly, and APKRun restored the old version. App data is not rolled back: data changed by the new version stays as it is |
| `rollbackUnavailable` | `completed(.keptAfterFailedHealthCheck(reason))` | APKRun can restore the old version only by erasing the app's data. Actions: **Keep ‹new version›**, and **Restore ‹old version› (Erases Data)…**. The second asks again, then runs `rollbackPackage(id, allowDataLoss: true)` |
| `rollbackFailed` | package `broken` | "APKRun could not restore ‹App›." with **Repair** |

The data warning is shown every time: in the notification, in the history, and in the UI. Data rollback is not in v1 ([package-store.md](package-store.md) §7.3).

### 8.4 Skipped versions

- A rolled-back version is added to the package's `skippedVersions`. V6 refuses it, so the next check does not install it again. A higher versionCode is tried normally.
- The user can skip an available version ("Skip This Version" in notify-only mode). The staged set is discarded (`discardStaged`).
- "Try Again" in the history removes a version from the list (`unskipVersion`). `apkrun update unskip <package> <versionCode>` does the same ([cli.md](cli.md) §4.3).

### 8.5 User-initiated rollback

"Roll Back to ‹previous version›" in the package's settings, and `apkrun rollback <package>`, are available while `previous/` exists. They run `rollingBack(.userRequested)` with the same store operation and messages. The rolled-back version is added to `skippedVersions`.

---

## 9. User-facing surfaces

The screens are designed in [host-ui.md](host-ui.md). The update system provides this state:

| Surface | Content | Task |
|---|---|---|
| Home, package row | "Updates: Automatic / Notify only / Manual". Status: "Up to date", "Update available ‹version›" with **Update Now**, "Updating…", "Will update when ‹App› quits", or "Update failed" | #077 |
| Package settings → Updates | the choices of §2.3, provider picker and configuration, "Check Now", last check time and result, history, "Roll Back to…", `update.autoRollback`, `update.healthCheckLaunch` | #079 |
| Menu bar | "Updates: 2 available" and the list with **Update** | #086 |
| CLI | §11.3 | #074 |

Notifications come from `HostNotifier` in RuntimeHost. Desktop integration uses it too, for apps without a wrapper ([desktop-integration.md](desktop-integration.md) §5.3). apkrund has no user-interface identity. It asks APKRun.app to post notifications over the `hostNotifications` stream. APKRunMenuBar never posts notifications ([host-ui.md](host-ui.md) §11). If APKRun.app is not connected, apkrund opens it in the background (`NSWorkspace.OpenConfiguration.activates = false`, argument `--notify`). APKRun.app posts the pending notifications without opening a window, and quits after 30 s if the user does nothing. Notification actions return through `hostNotificationResponse` ([runtime-api.md](../03-reference/runtime-api.md) §11.3).

| Notification | When | Default |
|---|---|---|
| Update available | a `notifyOnly` package reaches `available` | on |
| Updated | an automatic update passed its health check | **off** (`updates.notifyInstalled`) |
| Waiting to install | §7.4 | on |
| Rolled back, or kept after a failed health check | §8.3 | always |
| Update refused | V3 or V5 failed (a signer or metadata mismatch can mean a compromised source) | always |
| Update source problem | three consecutive check failures, or an index signature failure | on |

---

## 10. Persistence

### 10.1 `Updates/state.json`

Owned by `UpdateStateStore`. Written atomically (temporary file, barrier fsync, rename), at most once per second (coalesced).

```json
{
  "schemaVersion": 1,
  "packages": {
    "com.example.app": {
      "lastCheckAt": "2026-10-02T09:00:00Z",
      "nextCheckAt": "2026-10-02T15:21:00Z",
      "consecutiveFailures": 0,
      "cursor": { "type": "direct", "value": "W/\"5f2c…\"" },
      "phase": "staged",
      "candidate": { "versionCode": 45, "versionName": "4.5.0", "provider": "direct" },
      "stagedAt": "2026-10-02T09:01:10Z",
      "waitingNotifiedAt": null,
      "skippedVersions": [43]
    }
  }
}
```

- `phase` is saved only for `available` and `staged`. The other phases are transient. After a restart, a staged set in `Packages/<id>/staged/` is `staged`. An interrupted install is recovered by the store's journal ([package-store.md](package-store.md) §5.5). Then UpdateCore runs the health check for an update whose `lastOperation.healthPending` is still set.
- A missing or unreadable file is rebuilt with every package due now. That is safe, because cursors only save work.

### 10.2 `Updates/history.jsonl`

One line per run (§5), with the schema version `v` ([runtime-maintenance.md](runtime-maintenance.md) §5). Each line holds the time, package, from → to, provider, trigger (`scheduled`, `userInitiated`, `manual`, `launchOpportunistic`), outcome, failure, validation summary, health level and result, and phase durations. Retention: 365 days or 5 000 lines, whichever is less. Diagnostics bundles include it. It never holds URLs with query strings or tokens.

---

## 11. Runtime API surface

### 11.1 Operations

The DTOs are in [runtime-api.md](../03-reference/runtime-api.md).

| Operation | Behavior | Long operation |
|---|---|---|
| `checkForUpdates(packages: [PackageID]?)` | user-initiated check of the given packages, or of all `apkrun` packages | yes (per-package results) |
| `listUpdates()` | per package: phase, candidate, last check, next check, waiting reason (which gate condition is false) | no |
| `updatePackage(id, UpdateNowOptions{closeRunningApp, file})` | §7.3. With `file`, a manual update from a file handle | yes |
| `setUpdatePolicy(id, UpdatePolicy{choice, provider})` | §2.3. Validates the provider configuration. For F-Droid and GitHub, makes one test request | no |
| `setUpdateAuthority(id, AuthorityChoice)` | §2.1. `.apkrun`, `.manual`, or `.external`, through `PackageStore.setUpdateAuthority` | no |
| `skipVersion(id, versionCode)` / `unskipVersion(id, versionCode)` | §8.4 | no |
| `rollbackPackage(id, allowDataLoss)` | §8.5 (a store operation, [package-store.md](package-store.md) §11.1) | yes |
| `updateHistory(id?, limit)` | history entries | no |

Authorization: the `.control` endpoint only. Wrappers get nothing from UpdateCore.

### 11.2 Events

Topic `updates`:

```swift
public enum UpdateEvent: Codable, Sendable {
    case phaseChanged(PackageID, UpdatePhase)
    case progress(PackageID, OperationID, fraction: Double)      // download and install, coalesced to 10 Hz
    case finished(PackageID, UpdateOutcome)
    case summaryChanged(available: Int, waiting: Int, failed: Int)   // for the menu bar badge
}
```

### 11.3 CLI

The full syntax is in [cli.md](cli.md).

```text
apkrun update [--check-only] [--json]                 check every apkrun package now; install per mode (automatic ones gently)
apkrun update <package> [--now] [--file <apk>…]       check and install this package now (§7.3); --file = manual update
apkrun update policy <package> --mode automatic|notify|manual [--provider <spec> | --no-provider]
apkrun update authority <package> apkrun|manual|external
apkrun update skip <package> <versionCode>
apkrun update unskip <package> <versionCode>
apkrun update history [<package>] [--limit <n>] [--json]
apkrun rollback <package> [--allow-data-loss]
```

Provider specs: `local:<path>`, `direct:<https-url>`, `fdroid[:<repository-url>#<fingerprint>]`, and `github:<owner>/<name>[:<asset-glob>][@prerelease]`. The options `apkrun wrap … --update auto|notify|manual --update-provider direct --update-url <url>` and `--updates auto` are accepted as aliases.

---

## 12. Security

- Everything a provider returns is untrusted: manifests, indexes, release JSON, release notes, and APKs. Parsers have size limits: manifest 1 MiB, release JSON 4 MiB, index memory 64 MiB, release notes 16 KiB. They are fuzz targets (#091).
- HTTPS only, with default ATS and certificate validation. There is no certificate pinning, except the F-Droid index signing key, which is an application-level signature. Redirects go only to HTTPS. Debug builds also accept `http://127.0.0.1[:port]` and `http://localhost[:port]` for Direct manifest URLs and F-Droid repositories (§4.4, §4.5). Release builds refuse them when a provider is configured.
- The APK decides (FR-UPD-14). Provider metadata can cause only a refusal (V5), never an acceptance.
- No check can be disabled, and there is no "install anyway" (NFR-SEC-04).
- Tokens live in the Keychain. Logs show the provider type and host. They never show full URLs with query strings, tokens, or release notes (NFR-SEC-05).
- UpdateCore never installs for `googlePlay` or `external` packages, and never claims update ownership for them (§2.1).

---

## 13. Errors

`UpdateFailure` is UpdateCore's error domain. Codes, messages, and remediations are in [error-catalog.md](../03-reference/error-catalog.md) §11.

```swift
public enum UpdateFailure: APKRunError {
    case providerUnreachable(detail: String)
    case providerHTTPStatus(Int)
    case providerRateLimited(retryAfter: Date?)
    case providerMetadataInvalid(detail: String)
    case providerSignatureInvalid
    case providerNotConfigured
    case noCompatibleArtifact(NoArtifactReason)        // .abi, .sdk, .signerDiffers
    case ambiguousAsset([String])
    case downloadFailed(detail: String)
    case hashMismatch(file: String)
    case tooLarge(bytes: Int64)
    case validation(ValidationFailure)                 // §6
    case authorityDoesNotAllowUpdates(UpdateAuthority)
    case installFailed(StoreFailure)
    case healthCheckFailed(HealthCheckFailure)          // §8.1
    case rollbackFailed(StoreFailure)
    case cancelled
    // health findings (§14), never thrown
    case schedulerLate(duration: Duration)              // updates.scheduler
    case stagedTooLong(PackageID)                       // updates.waiting: staged for more than 7 days
}

public enum HealthCheckFailure: APKRunError {           // the post-install health check (§8)
    case versionNotConfirmed(found: VersionCode?)       // H1: Android does not report the staged versionCode and signer within 30 s. nil when it reports none
    case launchFailed
    case processDied(ProcessDeath)
    case noFirstFrame
}

public enum ProcessDeath: String, Sendable, Codable {
    case crash, anr
}

public enum ValidationFailure: APKRunError {
    case intrinsic(StoreFailure)
    case packageMismatch(expected: PackageID, found: PackageID)
    case notNewer(installed: VersionCode, candidate: VersionCode)
    case downgrade(installed: VersionCode, candidate: VersionCode)
    case signerMismatch
    case lineageMissingCapability
    case providerHashMismatch(file: String)
    case providerMetadataMismatch(field: String)
    case skippedVersion(VersionCode)
}
```

---

## 14. Logging, markers, health

- `os_log` subsystem `io.apkrun.update`; categories `scheduler`, `provider`, `validate`, `install`, `health`. Each run logs its trigger, provider type and host, cursor change, candidate versionCode, each check's verdict, gate evaluations (which condition was false), health steps, and outcome.
- Perf markers ([diagnostics.md](diagnostics.md) §4): `UPDATE_CHECK_START`, `UPDATE_CHECK_END`, `UPDATE_DOWNLOAD_START`, `UPDATE_DOWNLOAD_END`, `UPDATE_INSTALL_START`, `UPDATE_INSTALL_END`, `UPDATE_HEALTH_END`, `UPDATE_ROLLBACK_END`.

| Health check | Warning | Error |
|---|---|---|
| `updates.scheduler` | no scheduler run for 2 × the interval while apkrund was running (`update.schedulerLate`) | — |
| `updates.providers` | a package with 3 consecutive check failures | an F-Droid repository whose index signature failed |
| `updates.waiting` | an update staged for more than 7 days (`update.stagedTooLong`) | — |
| `updates.failed` | a package whose last update was rolled back or kept after a failed health check | — |

---

## 16. Tests

- **T0**, `Packages/UpdateCore/Tests/UpdateCoreTests/`: authority and mode mapping and defaults (§2); validation matrix V0–V6 with fixtures, including the rotation cases; Direct manifest schema (valid, missing `sha256`, HTTP URL, relative URL, oversized, wrong package); F-Droid `entry.jar` verification with a test key (valid, tampered `entry.json`, wrong fingerprint, unsigned) and version selection by ABI, SDK, and signer; GitHub asset choice and cursor logic from recorded API responses.
- **T1**, `Packages/UpdateCore/Tests/UpdateCoreTests/` and `Tests/IntegrationTests/UpdateTests/`:
  - Scheduler with a fake clock, network path, and providers: intervals, jitter bounds, backoff, rate limits, triggers, exclusion of transient phases, replacement of a staged candidate.
  - Coordinator end to end with a fake store and runtime: every phase transition of [state-machines.md](../01-architecture/state-machines.md) §6, and restart in each persisted phase.
  - Gentle-update conditions GU1–GU7 and the session and transaction races of §7.2, with a fake SessionRegistry.
  - Health checker levels and timeouts with a scripted runtime.
  - GitHub provider against a local mock of the REST API on `127.0.0.1`, serving recorded responses: release listing, the misleading tag `v0.1`, `ambiguousAsset`, rate-limit headers, the optional token. The fixture repository `apkrun-fixtures/helloupdate-releases` can replace the mock.
- **T2**, `Tests/IntegrationTests/UpdateTests/`, needs a VM:
  - LocalProvider V1 → V2 with data kept, on the stock image and the custom image. HelloUpdate V1 writes `HELLO` into its data directory, and V2 must still read it. Fixtures: `Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/{1,2}/`, built from the HelloUpdate V1 and V2 apps in `Tests/Fixtures/AndroidApps/`.
  - Gentle update acceptance (G7): V2 installs within 30 s after the app quits, and never while the window is open (checked for 10 minutes).
  - Broken-update rollback on both image kinds, and the rollback-unavailable path with the confirmed data-loss fallback.
  - Wrapper unchanged across an automatic update (G9). Generate `HelloUpdate.app` for V1 and record the SHA-256 of every file (`APKRunLauncher`, `Info.plist`, `wrapper.json`, `AppIcon.icns`, `_CodeSignature/`). After the update, every hash is unchanged, and the cdhash in `Wrappers/registry.json` is unchanged.
  - DirectProvider against the local test service (`scripts/dev/update-server.py`, Debug builds only, serving `Tests/Fixtures/update-repos/direct/` on `http://127.0.0.1:<port>`). `--delay <seconds>` delays every answer, for the slow-provider test of §3.
  - F-Droid test repository (built with `fdroid update` in CI, signed with a test key) and the GitHub mock.
- **T3**, nightly, network: the gate checks G7 (`G7GentleUpdate`) and G9 (`G9WrapperIntegrity`) on the reference Mac ([test-strategy.md](../04-plan/test-strategy.md) §5). The F-Droid main repository and a real GitHub release.

---

## 17. Open items

- `GENTLE_UPDATE` and foreground services (OQ-17, §7.1).
- F-Droid index field names, the diff format, and the main repository fingerprint (OQ-18, §4.5). GitHub asset `digest` availability (OQ-18, §4.6).
- Signed Direct manifests, v1.x (OQ-19, §4.4).
- Visible side effects of health-check launches on real apps (OQ-20, §8.1). If they occur, the default level may change to `processOnly` without H2's visible work, or to `versionOnly`.
- Resuming partial downloads, v1.x (OQ-21, §5).
- Data rollback, post-v1 (OQ-16, [package-store.md](package-store.md) §7.3).
