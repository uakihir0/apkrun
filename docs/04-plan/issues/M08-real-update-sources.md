# M8 Real update sources

| Field | Value |
|---|---|
| Status | Baseline |
| Version | v0.5 |
| Related | [../traceability.md](../traceability.md), [../roadmap.md](../roadmap.md), [../risks.md](../risks.md), [../test-strategy.md](../test-strategy.md), [../open-questions.md](../open-questions.md), [../../05-development/workflow.md](../../05-development/workflow.md), [../../../AGENTS.md](../../../AGENTS.md) |

## Milestone goal

APKRun updates Android apps from the two public app sources that do not need Google Play: F-Droid repositories and GitHub Releases (M8; "GitHubProvider", "F-DroidProvider"). Both providers use the provider protocol and the validation pipeline of M6 without change. Provider metadata can only cause a refusal. The package name, versionCode, and signer inside the downloaded APK decide every update (FR-UPD-14, [update-system.md](../../02-design/update-system.md) §6, §12).

## Exit criteria

- [ ] #051 and #052 meet all their acceptance criteria, or a task is moved to a later milestone with the reason recorded in this file ([../roadmap.md](../roadmap.md) §4).
- [ ] FR-UPD-13 and the GitHub part of FR-UPD-14 are covered by passing tests ([../traceability.md](../traceability.md) §2).
- [ ] The T0 and T1 suites pass on `main`. The T2 tests "F-Droid test repository" and "GitHub mock" pass on the reference Mac. The T3 checks against the F-Droid main repository and a real GitHub release are in the nightly run ([update-system.md](../../02-design/update-system.md) §16).
- [ ] The verifications that [update-system.md](../../02-design/update-system.md) §4.5 and §4.6 ask for are done: the F-Droid index v2 field names, the diff format, the main repository fingerprint, and the availability of the GitHub asset `digest`. §4.5 and §4.6 are corrected where the real format differs, and the matching entry in [../open-questions.md](../open-questions.md) is settled.
- [ ] The perf harness numbers are recorded for the milestone. The launch path has no synchronous update check (NFR-PERF-07), and any regression is explained ([../../02-design/diagnostics.md](../../02-design/diagnostics.md) §9.4).
- [ ] [update-system.md](../../02-design/update-system.md) describes what was built. The v0.5 items "GitHubProvider" and "F-DroidProvider" are marked delivered in [../roadmap.md](../roadmap.md) §3.5. v0.5 is checked and tagged after M11.

## Task order

1. #051 F-Droid provider. **Parallel with #052.**
2. #052 GitHub provider. **Parallel with #051.**

Both tasks depend only on #050 (M6). They touch different files in `Packages/UpdateCore/` and share only `ProviderRegistry`, the provider spec parser, and `scripts/dev/update-server.py`. Merge conflicts there are small.

---

## #051 F-Droid provider

| Field | Value |
|---|---|
| Milestone | M8 (v0.5) |
| Depends on | #050 |
| Requirements | FR-UPD-13. Constraints: NFR-SEC-04 (no bypass of signature checks), NFR-SEC-05 (logs), NFR-PERF-07 (no update work on the launch path) |
| Design | [update-system.md](../../02-design/update-system.md) §4.5, §4.1, §4.2, §4.7, §5, §6, §9, §11, §12, §13, §14, §15 (#051), §16; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §5; [host-ui.md](../../02-design/host-ui.md) §7.5 |
| Modules / paths | `Packages/UpdateCore/Sources/UpdateCore/Providers/` (`FDroidProvider.swift`, `FDroidIndexVerifier.swift`, `FDroidIndexReader.swift`), `Packages/UpdateCore/Tests/UpdateCoreTests/`, `CLI/apkrun/` (provider spec), `Apps/APKRun/` (package settings text), `Tests/Fixtures/update-repos/fdroid/`, `Tests/Fixtures/signing/`, `scripts/dev/update-server.py`, `Tests/IntegrationTests/`, `Tests/AcceptanceTests/` |
| Risks / questions | None in [../risks.md](../risks.md). Open items: [update-system.md](../../02-design/update-system.md) §17 (F-Droid index format details and the main repository fingerprint) |

### Goal

With the F-Droid provider set for a package, APKRun finds a newer version in a signed F-Droid v2 repository and installs it through the normal update pipeline. An index whose signature does not match the pinned fingerprint is refused, and a version with a different signer is never installed.

### Scope

- `FDroidProvider` conforming to `UpdateProvider` ([update-system.md](../../02-design/update-system.md) §4.1), registered in `ProviderRegistry` as `.fdroid`.
- Configuration `{repository, fingerprint}`. The default is the main repository `https://f-droid.org/repo` with the fingerprint pinned in the app.
- `entry.jar` verification, full index and diffs with SHA-256 checks, the index cache, and a streaming decoder with a 64 MiB memory budget.
- `check` (version selection by versionCode, ABI, SDK, and signer) and `download`.
- Signer-mismatch handling and its text in package settings.
- The provider spec `fdroid[:<repository-url>#<fingerprint>]`, the test request of `setUpdatePolicy`, logs, markers, the `updates.providers` health check, and the "Update source problem" notification for an index signature failure.
- The F-Droid lookup that the Add sheet's provider suggestion uses ([update-system.md](../../02-design/update-system.md) §4.7).
- The controlled test repository and its local server.

Out of scope:

- Browsing or searching F-Droid repositories. There is no app catalog in v1 ([host-ui.md](../../02-design/host-ui.md) §16, [../open-questions.md](../open-questions.md)).
- Installing across signers, or any "install anyway" path (NFR-SEC-04).
- The legacy v1 index (`index-v1.jar`). Only the signed v2 index is supported.
- Resuming partial downloads (v1.x, [update-system.md](../../02-design/update-system.md) §5).
- The GitHub provider (#052). Fuzzing the index decoder (#091).

### Deliverables

- `Packages/UpdateCore/Sources/UpdateCore/Providers/FDroidProvider.swift`, `FDroidIndexVerifier.swift` (`entry.jar`), and `FDroidIndexReader.swift` (streaming decode, diff merge, cache).
- The `.fdroid` case in `ProviderRegistry` and in the provider spec parser used by `apkrun update policy` and `apkrun install --provider` ([cli.md](../../02-design/cli.md) §3.1, §4.2, §4.3, [update-system.md](../../02-design/update-system.md) §11.3).
- The signer-mismatch text and the F-Droid provider configuration in package settings → Updates ([host-ui.md](../../02-design/host-ui.md) §7.5).
- `Tests/Fixtures/update-repos/fdroid/`: a repository built in CI by `fdroid update` from the HelloUpdate V1 and V2 builds, with its index signed by the test key `Tests/Fixtures/signing/test-fdroid-repo.*`.
- An F-Droid mode in `scripts/dev/update-server.py` that serves this repository on `http://127.0.0.1:<port>/repo` (Debug builds only).
- T0 and T1 tests in `Packages/UpdateCore/Tests/UpdateCoreTests/`, the T2 test in `Tests/IntegrationTests/`, and the nightly T3 check in `Tests/AcceptanceTests/`.
- [update-system.md](../../02-design/update-system.md) §4.5 updated with the verified field names, the diff format, and the main repository fingerprint.

### Implementation steps

The design steps are [update-system.md](../../02-design/update-system.md) §15 #051, steps 1–3. Step 1 is split into steps 1–4 here, step 2 is step 5, and step 3 is steps 8–9.

1. **Verify the index format (design step 1).** Before writing the decoder, compare the field names of §4.5 (`entry.json` index and diff entries, `packages[<id>].versions`, `manifest.versionCode`, `manifest.nativecode`, `manifest.usesSdk.minSdkVersion`, `manifest.signer.sha256`, `file.name`, `file.sha256`, `file.size`) and the main repository fingerprint with the current F-Droid index documentation and a downloaded `entry.jar`. Correct §4.5 in the same pull request if they differ. Check: §4.5 matches the real format, and the pull request says what was checked.
2. **`entry.jar` verification (design step 1).** `FDroidIndexVerifier` downloads `<repository>/entry.jar` with `ProviderContext.http` and reads its entries with ZIPFoundation (add the `ZIPFoundation` dependency to the `UpdateCore` target in the root `Package.swift`, ADR-0017; at most 16 entries and 16 MiB in total, otherwise `providerMetadataInvalid`). It verifies, in order: the CMS signature over `META-INF/*.SF` with Security.framework `CMSDecoder`, the signer certificate's SHA-256 against the configured fingerprint, the `.SF` digests of `MANIFEST.MF`, and the manifest digest of `entry.json`. Every failure is `UpdateFailure.providerSignatureInvalid`. It sets the `updates.providers` health check to error, posts the "Update source problem" notification (§9), and stops all updates from that repository until a later check verifies. HTTPS only, with redirects only to HTTPS. Debug builds also allow `http://127.0.0.1` (§12). Check: the T0 verifier cases pass (valid, tampered `entry.json`, wrong fingerprint, unsigned).
3. **Index, diffs, and cache (design step 1).** `entry.json` names the full index (`index-v2.json`) and the diffs from earlier timestamps, each with a SHA-256. If a cached index exists and `entry.json` lists a diff from its timestamp, download the diff; otherwise download the full index. Check the SHA-256 against `entry.json`, then merge. The cache is `Providers/cache/fdroid/<first 16 hex of SHA-256(repository)>/` ([../../01-architecture/filesystem-layout.md](../../01-architecture/filesystem-layout.md)). The index is refreshed at most once per check interval for all packages together. A SHA-256 mismatch is `providerMetadataInvalid(detail:)`, the file is discarded, and the next check downloads it again. Check: T0 shows that a cached index plus a diff equals the next full index, and that a second check inside the interval makes no index request.
4. **Streaming decode (design step 1).** `FDroidIndexReader` decodes the index with a streaming JSON reader. It keeps only the packages that APKRun manages with an F-Droid provider, plus the package IDs it is asked about (the `setUpdatePolicy` test request and the Add-sheet lookup of step 7). Peak memory stays within 64 MiB (§4.5, §12). Keep the decoder callable on a byte buffer with no network, so #091 can fuzz it. Check: the T1 memory test passes.
5. **`check` and `download` (§4.5).** Among `packages[<id>].versions`, the candidate is the highest `manifest.versionCode` that is greater than the installed one, whose `manifest.nativecode` is empty or contains a guest ABI, whose `manifest.usesSdk.minSdkVersion` is at most the guest SDK, and whose `manifest.signer.sha256` equals the installed signer set. The `UpdateCandidate` has `declaredVersionCode`, `declaredVersionName`, `declaredSignerDigests`, one `RemoteArtifact` at `<repository>/<file.name>` with `file.sha256` and `file.size`, and cursor = index timestamp + chosen version hash. When the saved cursor matches, `check` returns nil (§4.2). `download` streams into `Packages/<id>/incoming/<ticket>/` while hashing. The §5 pipeline rules apply unchanged: 8 GiB cap, one retry on a hash mismatch, network retries after 10 s and 60 s. V0–V6 run unchanged. V4 always applies to F-Droid, and V5 compares the declared versionCode and signer with the APK (§6). Check: T0 version selection by ABI, SDK, and signer passes.
6. **Signer mismatch (design step 2).** When versions exist but none has the installed signer, `check` returns nil and records `noCompatibleArtifact(.signerDiffers)` as the check result. Package settings → Updates then show, verbatim: "F-Droid's builds of ‹App› are signed by F-Droid, not by the developer of the installed copy. To use F-Droid updates, uninstall ‹App› and install it from F-Droid." APKRun never installs across signers. Check: a T0 test gives `.signerDiffers` for a fixture index whose versions have another signer, and a model test shows the text.
7. **Configuration, CLI, and suggestion (§4.7, §11).** Validate the configuration: `repository` is an HTTPS URL (Debug builds also accept the loopback URL of the test server, [update-system.md](../../02-design/update-system.md) §12), and `fingerprint` is 64 hex digits. `setUpdatePolicy` makes one test request: download and verify `entry.jar`, and look up the package. Parse `fdroid[:<repository-url>#<fingerprint>]`, where a bare `fdroid` means the main repository. Add F-Droid to the provider picker in package settings. Provide the Add-sheet lookup: suggest F-Droid only when the package ID is in the cached main-repository index and a version there has the imported signer. The suggestion stays off until the user turns it on. Logs use subsystem `io.apkrun.update`, category `provider`, with the provider type and host only. Emit `UPDATE_CHECK_START`/`END` and `UPDATE_DOWNLOAD_START`/`END` (§14). Check: in a Debug build, `apkrun update policy io.apkrun.fixture.helloupdate --mode automatic --provider fdroid:http://127.0.0.1:<port>/repo#<test fingerprint>` succeeds, and the same command with a wrong fingerprint fails with `providerSignatureInvalid`.
8. **Controlled test repository (design step 3).** A CI job runs `fdroid update` on the HelloUpdate V1 and V2 APKs (package `io.apkrun.fixture.helloupdate`, signed with the fixture app key) and signs the index with `Tests/Fixtures/signing/test-fdroid-repo.*`. The output goes to `Tests/Fixtures/update-repos/fdroid/`. `scripts/dev/update-server.py` serves it in its F-Droid mode. The tampered copy is made by the test itself: one byte changed in `entry.json` inside `entry.jar`. Check: the CI output passes the T0 verifier with the test fingerprint.
9. **Acceptance (design step 3).** Run the T2 and T3 tests below. Record the results of step 1 in §4.5 and in [../open-questions.md](../open-questions.md). Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`): `entry.jar` verification with the test repository key (valid, tampered `entry.json`, wrong fingerprint, unsigned). Version selection by ABI, SDK, and signer. Cursor handling, and nil for a saved cursor. Diff merge against the next full index. The `.signerDiffers` result. Configuration and spec parsing. The Add-sheet lookup. Log output that has the host but no path or query.
- **T1**: `FDroidProvider` against `scripts/dev/update-server.py` on `127.0.0.1` with a fake store: first check with the full index, a later check with a diff, a check inside the interval with no request, and a hash mismatch on the index. Decoding a generated index at least as large as the main index keeps peak memory within 64 MiB.
- **T2** (`Tests/IntegrationTests/`, custom image): with HelloUpdate V1 installed and the F-Droid provider set to the test repository, APKRun discovers V2 and installs it. With the tampered `entry.jar`, nothing is installed and the refusal is reported.
- **T3** (`Tests/AcceptanceTests/`, nightly, network): against `https://f-droid.org/repo` with the pinned fingerprint, the index verifies and one known package (`org.fdroid.fdroid`) is found with at least one version that matches the guest ABI and SDK.

### Acceptance criteria

- [ ] A controlled F-Droid test repository, built with `fdroid update` in CI and signed with a test key, serves two versions of HelloUpdate. With V1 installed, APKRun discovers V2 and installs it (T2).
- [ ] A tampered `entry.jar` (one byte changed in `entry.json`) is refused with `providerSignatureInvalid`. Nothing from that repository is installed, `updates.providers` reports an error, and the "Update source problem" notification is posted.
- [ ] An `entry.jar` with a wrong fingerprint or with no signature is refused (T0).
- [ ] Every F-Droid candidate passes V0–V6 before staging. V4 checks `file.sha256`, and V5 refuses a candidate whose declared versionCode or signer differs from the APK.
- [ ] A version whose signer differs from the installed signer is never a candidate. `check` records `noCompatibleArtifact(.signerDiffers)`, and package settings show the §4.5 text.
- [ ] Version selection skips versions whose `nativecode` has no guest ABI or whose `minSdkVersion` is above the guest SDK (T0).
- [ ] A diff is used when the cache has its base timestamp. The index is fetched at most once per check interval for all packages, and the cached index plus the diff equals the full index.
- [ ] Decoding stays within the 64 MiB memory budget (T1).
- [ ] Logs show the provider type and host only (NFR-SEC-05).
- [ ] (T3, nightly) Against the real main repository, one known package is discovered.
- [ ] The index field names, the diff format, and the main repository fingerprint are verified. [update-system.md](../../02-design/update-system.md) §4.5 matches the real format.

### Notes

- **Record:** the verified field names, the diff format, the `.SF` digest algorithm, and the fingerprint go into [update-system.md](../../02-design/update-system.md) §4.5 and the F-Droid entry of [../open-questions.md](../open-questions.md).
- **Pitfall:** F-Droid signs most apps itself. A user who installed an app from its developer usually gets `.signerDiffers`. That is correct behavior, not a bug. The fixture repository must hold APKs signed with the fixture app key, so that V1 and V2 have the same signer.
- **Pitfall:** verify the `.SF` file with the digest algorithm it declares. Never accept an entry that has no digest.
- The index SHA-256 mismatch is mapped to `providerMetadataInvalid` rather than `providerSignatureInvalid`, because the signed `entry.json` was valid and the likely cause is a mirror that is still updating. The design does not name this case.
- The decoder and the `entry.jar` parser are fuzz targets of #091 ([update-system.md](../../02-design/update-system.md) §12).

---

## #052 GitHub provider

| Field | Value |
|---|---|
| Milestone | M8 (v0.5) |
| Depends on | #050 |
| Requirements | FR-UPD-13, FR-UPD-14. Constraints: NFR-SEC-04, NFR-SEC-05 (no tokens in logs), NFR-PERF-07 |
| Design | [update-system.md](../../02-design/update-system.md) §4.6, §4.1, §4.2, §5, §6, §10.2, §11, §12, §13, §14, §15 (#052), §16; [../../01-architecture/security-model.md](../../01-architecture/security-model.md) §5; [host-ui.md](../../02-design/host-ui.md) §7.5 |
| Modules / paths | `Packages/UpdateCore/Sources/UpdateCore/Providers/GitHubProvider.swift`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `CLI/apkrun/` (provider spec), `Apps/APKRun/` (provider configuration and token field), `Tests/Fixtures/update-repos/github/`, `scripts/dev/update-server.py`, `Tests/IntegrationTests/`, `Tests/AcceptanceTests/` |
| Risks / questions | None in [../risks.md](../risks.md). Open items: [update-system.md](../../02-design/update-system.md) §17 (GitHub asset `digest` availability) |

### Goal

With the GitHub provider set for a package, APKRun finds the newest matching APK asset in a repository's releases, downloads it, and decides the update from the APK's own versionCode and signer, never from the release tag.

### Scope

- `GitHubProvider` conforming to `UpdateProvider`, registered as `.github`.
- Configuration `{repository: "owner/name", assetPattern: "*.apk", channel: "stable" | "prerelease"}` (repository, asset pattern, optional release channel).
- The optional personal access token in the Keychain (service `io.apkrun.provider.github`).
- Release listing with conditional requests, release choice, asset choice with ABI preference, `ambiguousAsset`, the asset digest, cursors, and rate-limit handling.
- The provider spec `github:<owner>/<name>[:<asset-glob>][@prerelease]` and the test request of `setUpdatePolicy`.
- Recorded API responses, a local GitHub REST mock, and the fixture repository `apkrun-fixtures/helloupdate-releases`.

Out of scope:

- Guessing a GitHub provider for an imported package. GitHub is never guessed ([update-system.md](../../02-design/update-system.md) §4.7).
- Using the tag or the release name as a version (#052).
- GitHub Enterprise hosts, GitHub Actions artifacts, and source archives.
- A CLI option for the token.
- Resuming partial downloads (v1.x). Fuzzing the release decoder (#091).

### Deliverables

- `Packages/UpdateCore/Sources/UpdateCore/Providers/GitHubProvider.swift`, with the release decoder and the asset matcher.
- The `.github` case in `ProviderRegistry` and in the provider spec parser.
- The GitHub configuration in package settings → Updates, with an optional secure token field ([host-ui.md](../../02-design/host-ui.md) §7.5).
- `Tests/Fixtures/update-repos/github/`: recorded API responses and the HelloUpdate V1 and V2 assets.
- A GitHub REST mock mode in `scripts/dev/update-server.py` (Debug builds only).
- The fixture repository `apkrun-fixtures/helloupdate-releases` on GitHub, with releases for V1 and V2 (V2 tagged `v0.1`).
- T0 and T1 tests, the T2 test, and the nightly T3 check.
- [update-system.md](../../02-design/update-system.md) §4.6 updated with the verified `digest` behavior.

### Implementation steps

The design steps are [update-system.md](../../02-design/update-system.md) §15 #052, steps 1–2. Step 1 is split into steps 1–5 here, and step 2 is steps 6–7.

1. **Configuration and token (design step 1).** Add `GitHubConfiguration` with `repository` (`owner/name`), `assetPattern` (glob, default `*.apk`), and `channel` (`stable` default, or `prerelease`). The optional personal access token is read through `ProviderContext.credentials` from the Keychain, service `io.apkrun.provider.github`. It is never written to `settings.json`, logs, history, or diagnostics. Package settings have a secure field for it. The value goes to apkrund in the `setUpdatePolicy` request only, and apkrund writes it to the Keychain. DTOs report only whether a token is set. Parse `github:<owner>/<name>[:<asset-glob>][@prerelease]`. `setUpdatePolicy` makes one test request (the release listing). Check: T0 spec parsing, and a T1 test shows that the token is not in `settings.json`, `history.jsonl`, or the log output.
2. **Release listing (design step 1).** `GET https://api.github.com/repos/{owner}/{name}/releases?per_page=10` with `Accept: application/vnd.github+json`, `X-GitHub-Api-Version`, `If-None-Match` with the cached ETag, and `Authorization` only when a token is set. `304` means nil. The body is at most 4 MiB (§12). The chosen release is the newest non-draft release. Pre-releases are chosen only on the `prerelease` channel. The cache (ETag and the last response) is under `Providers/cache/github/<key>/`. Check: T0 with recorded responses picks the right release for each channel and never a draft.
3. **Asset choice and candidate (design step 1).** Match asset names against `assetPattern`. If several match, prefer names that contain `arm64-v8a` or `arm64`, then `universal`. If several still match, fail with `ambiguousAsset(names)`. If none matches, fail with `providerMetadataInvalid(detail:)` so the check result names the pattern. The candidate has `declaredVersionCode = nil` and `declaredVersionName = nil`: the tag and the release name are **not** versions (#052). Release notes are the release body as plain text, at most 16 KiB. `publishedAt` is the release's `published_at`. The hash is the asset's `digest` (`sha256:…`) when the API provides it, which makes V4 apply. Otherwise the download is protected by TLS only, and the history entry says "No checksum published". Check: the T0 asset-choice cases pass.
4. **Cursor and download (design step 1).** Cursor = release ID + asset ID + asset `updated_at` + size. When the saved cursor matches, `check` returns nil (§4.2). Because the version is known only after the download, the cursor is what keeps APKRun from downloading a non-newer asset twice. `download` fetches the asset over HTTPS, following at most 5 redirects, and only to HTTPS. The token is sent to `api.github.com` only, never to a redirect host. Then V0–V6 run unchanged, and V2 decides from the APK's versionCode. A non-newer APK ends as `validationFailed(.notNewer)` with the cursor saved (§5). Check: a T0 test shows that the second check for the same asset returns nil.
5. **Rate limits (design step 1).** `403` or `429` with `x-ratelimit-remaining: 0` becomes `providerRateLimited(retryAfter:)`, with the date from `x-ratelimit-reset`. The scheduler does not check the provider again before that date ([update-system.md](../../02-design/update-system.md) §3.2). Conditional requests that return `304` are cheap. Unauthenticated use (60 requests per hour per IP) is enough for dozens of packages at the default interval. Logs use `io.apkrun.update`/`provider` with the provider type and host only, with the §14 markers. Check: the T1 rate-limit case passes.
6. **Fixtures and mock (design step 2).** Record the API responses in `Tests/Fixtures/update-repos/github/`: releases for V1 and V2 with V2 tagged `v0.1`, a release with two matching assets and no ABI hint, a draft, a pre-release, an asset with `digest` and one without, and a rate-limit response with its headers. Add a GitHub REST mock mode to `scripts/dev/update-server.py` that serves these responses and the assets on `127.0.0.1`, honors `If-None-Match`, and redirects asset downloads to a second local path. Debug builds let the provider configuration carry an API base URL that points at the mock. Release builds ignore it. Create `apkrun-fixtures/helloupdate-releases` with the same V1 and V2 releases. Check: the mock serves the recorded responses byte for byte.
7. **Acceptance (design step 2).** Run the T1, T2, and T3 tests below. Record whether real release assets carry `digest`, in §4.6 and in [../open-questions.md](../open-questions.md). Check: every acceptance criterion is checked.

### Tests

By tier ([../test-strategy.md](../test-strategy.md)):

- **T0** (`Packages/UpdateCore/Tests/UpdateCoreTests/`): asset choice and cursor logic from the recorded API responses: pattern matching, the `arm64-v8a`/`arm64`, then `universal` preference, `ambiguousAsset`, no matching asset, drafts, the pre-release channel, the tag being ignored, `digest` parsing, and the rate-limit mapping.
- **T1**: `GitHubProvider` against the local REST mock with a fake store: `304` on an unchanged ETag, the rate-limit response, the redirect to the asset host with no `Authorization` header there, and the token absent from settings, history, and logs.
- **T2** (`Tests/IntegrationTests/`): with HelloUpdate V1 installed and the provider pointed at the mock, the V2 release tagged `v0.1` is detected, the correct APK is downloaded, and V2 is installed, with the decision made from the APK's versionCode.
- **T3** (`Tests/AcceptanceTests/`, nightly, network): against `apkrun-fixtures/helloupdate-releases` on GitHub, the V2 asset is detected and downloaded, and the test records whether `digest` is present.

### Acceptance criteria

- [ ] A controlled release fixture (the local REST mock in T1 and T2, `apkrun-fixtures/helloupdate-releases` in T3) with releases for V1 and V2, and a misleading tag on V2 (`v0.1`), is detected, and the correct APK is downloaded.
- [ ] The update decision is made from the APK's versionCode (V2). The tag and the release name are never used as versions, and `declaredVersionCode` is nil.
- [ ] Two matching assets without an ABI hint give `ambiguousAsset(names)`.
- [ ] Draft releases are never chosen. Pre-releases are chosen only on the `prerelease` channel.
- [ ] An asset that was already downloaded and found not newer is not downloaded again (the cursor).
- [ ] When the asset has a `digest`, V4 checks it. Without one, the history entry says "No checksum published".
- [ ] A rate-limit response gives `providerRateLimited(retryAfter:)`, and no request is made before the reset time.
- [ ] The token is stored only in the Keychain (service `io.apkrun.provider.github`). It is not in `settings.json`, logs, or history, and it is not sent to any host other than `api.github.com`.
- [ ] The availability of the asset `digest` is verified, and [update-system.md](../../02-design/update-system.md) §4.6 states it.

### Notes

- **Record:** the `digest` result goes into [update-system.md](../../02-design/update-system.md) §4.6 and the GitHub entry of [../open-questions.md](../open-questions.md). Without `digest`, the APK signer check (V3) is the only protection beyond TLS.
- **Pitfall:** asset downloads redirect to another host. Do not forward the `Authorization` header across the redirect.
- **Pitfall:** release JSON, release notes, and asset names are untrusted input. Release notes are shown as plain text, never rendered as HTML ([update-system.md](../../02-design/update-system.md) §4.1, §12).
- The token travels only from the client to apkrund, in `ProviderSpec.token` of `setUpdatePolicy`. Replies carry only `ProviderSummary.hasToken` ([runtime-api.md](../../03-reference/runtime-api.md) §9.2).
- The release decoder is a fuzz target of #091 ([update-system.md](../../02-design/update-system.md) §12).
