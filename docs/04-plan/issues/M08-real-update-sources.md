# M8 Real update sources

M8 adds two public update sources that need no Google Play: F-Droid repositories (`.fdroid`) and GitHub Releases (`.github`). Both use the M6 provider protocol and validation pipeline unchanged. Provider metadata can only cause a refusal. The package name, versionCode, and signer of the downloaded APK decide every update ([update-system.md](../../02-design/update-system.md) §6). #051 and #052 can be built in parallel. They close no gate.

---

## #051 F-Droid provider

| Field | Value |
|---|---|
| Milestone | M8 (v0.5) |
| Depends on | #050 |
| Design | [update-system.md](../../02-design/update-system.md) §4.5, §4.7, §5, §6; [host-ui.md](../../02-design/host-ui.md) §7.5 |
| Code | `Packages/UpdateCore/Sources/UpdateCore/Providers/FDroid*.swift`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `Tests/Fixtures/update-repos/fdroid/`, `scripts/dev/update-server.py` |

**Goal.** APKRun installs a newer version found in a signed F-Droid v2 repository. A bad index signature is refused. A version with another signer is never installed.

**Out of scope.** Browsing F-Droid ([host-ui.md](../../02-design/host-ui.md) §16), `index-v1.jar`, and resuming downloads.

**Steps.**
1. **Verify the format.** Check the field names, diff format, and pinned fingerprint in [update-system.md](../../02-design/update-system.md) §4.5 against a real index and `entry.jar`. Correct [update-system.md](../../02-design/update-system.md) §4.5 where they differ. **Check:** the field names match the real format.
2. **`FDroidIndexVerifier`.** Verify `entry.jar` in the order of [update-system.md](../../02-design/update-system.md) §4.5 "Index verification", with ZIPFoundation (ADR-0017). Any failure is `UpdateFailure.providerSignatureInvalid`. It sets `updates.providers` to error and blocks the repository until a check verifies. HTTPS only; Debug builds also allow `http://127.0.0.1`. **Check:** T0 verifier cases pass.
3. **`FDroidIndexReader`.** Download the index or the diff that `entry.json` names, check its SHA-256, and merge. Cache under `Providers/cache/fdroid/` and fetch at most once per check interval. Stream-decode within 64 MiB, keeping managed and requested packages only. Take a byte buffer, so #091 can fuzz it. A hash mismatch is `providerMetadataInvalid(detail:)`. **Check:** T0 cached index plus diff equals the full index; the T1 memory test passes.
4. **`FDroidProvider` check and download.** Select the candidate, artifact, and cursor as [update-system.md](../../02-design/update-system.md) §4.5 `check` says. `download` streams into `Packages/<id>/incoming/<ticket>/` under [update-system.md](../../02-design/update-system.md) §5. V4 always applies, and V5 compares the declared values with the APK. When only other signers exist, record `noCompatibleArtifact(.signerDiffers)` and show the signer text of [update-system.md](../../02-design/update-system.md) §4.5. **Check:** T0 selection and `.signerDiffers` tests pass.
5. **Configuration and suggestion.** The spec is `fdroid[:<url>#<fingerprint>]`. A bare `fdroid` means the main repository with its pinned fingerprint. `setUpdatePolicy` makes one test request. The Add-sheet suggestion follows [update-system.md](../../02-design/update-system.md) §4.7. Logs use `io.apkrun.update`/`provider` with the host only. **Check:** `apkrun update policy io.apkrun.fixture.helloupdate --mode automatic --provider fdroid:http://127.0.0.1:<port>/repo#<test fingerprint>` succeeds, and a wrong fingerprint fails with `providerSignatureInvalid`.
6. **Test repository.** CI runs `fdroid update` on HelloUpdate V1 and V2 and signs the index with `Tests/Fixtures/signing/test-fdroid-repo.*`. The output goes to `Tests/Fixtures/update-repos/fdroid/`, which `scripts/dev/update-server.py` serves in Debug builds. **Check:** the CI output passes the T0 verifier with the test fingerprint.

**Tests.**
- T0 (`Packages/UpdateCore/Tests/UpdateCoreTests/`): verifier cases (valid, tampered, wrong fingerprint, unsigned), selection, cursor, diff merge, `.signerDiffers`, spec parsing, and logs without paths or queries.
- T1: `FDroidProvider` against `update-server.py`: full index, a diff, no request inside the interval, an index hash mismatch, and a 64 MiB decode.
- T2 (`Tests/IntegrationTests/`): V1 to V2 through the test repository. A tampered `entry.jar` installs nothing.
- T3 (nightly, network): the main repository verifies, and `org.fdroid.fdroid` has a version for the guest ABI and SDK.

**Done when.**
- With V1 installed, V2 is discovered and installed (T2).
- A tampered `entry.jar` gives `providerSignatureInvalid` and posts "Update source problem". Nothing is installed.
- A wrong-fingerprint or unsigned `entry.jar` is refused (T0).
- Every candidate passes V0–V6, and a version with another signer is never a candidate.
- Versions without a guest ABI, or with a too-high `minSdkVersion`, are skipped (T0).
- Decoding stays within 64 MiB (T1). Logs show the host only (NFR-SEC-05).

**Pitfalls.**
- F-Droid signs most apps itself, so a user who installed from the developer gets `.signerDiffers`. That is correct. The fixture uses the fixture app key, so V1 and V2 share a signer.
- Verify `.SF` files with the digest they declare. Never accept an entry without a digest.

---

## #052 GitHub provider

| Field | Value |
|---|---|
| Milestone | M8 (v0.5) |
| Depends on | #050 |
| Design | [update-system.md](../../02-design/update-system.md) §4.6, §4.7, §5, §6; [host-ui.md](../../02-design/host-ui.md) §7.5 |
| Code | `Packages/UpdateCore/Sources/UpdateCore/Providers/GitHubProvider.swift`, `Packages/UpdateCore/Tests/UpdateCoreTests/`, `Tests/Fixtures/update-repos/github/`, `scripts/dev/update-server.py` |

**Goal.** APKRun finds the newest matching APK asset in a repository's releases, downloads it, and decides the update from the APK's versionCode and signer. The release tag is never a version.

**Out of scope.** GitHub Enterprise, Actions artifacts, source archives, and a CLI option for the token.

**Steps.**
1. **Configuration and token.** Add `GitHubConfiguration` with `repository`, `assetPattern` (default `*.apk`), and `channel` (`stable` or `prerelease`). The optional token lives only in the Keychain, service `io.apkrun.provider.github`. It travels only in `ProviderSpec.token` of `setUpdatePolicy`. Replies carry `ProviderSummary.hasToken` ([runtime-api.md](../../03-reference/runtime-api.md) §9.2). Parse `github:<owner>/<name>[:<asset-glob>][@prerelease]`. **Check:** T0 spec tests pass, and a T1 test finds no token in settings, history, or logs.
2. **`GitHubProvider.check`.** Read the release listing and choose the asset as [update-system.md](../../02-design/update-system.md) §4.6 says, with `If-None-Match`, and `Authorization` only with a token. The candidate's declared versionCode and name are nil. The asset `digest` is the hash when present. The cursor follows [update-system.md](../../02-design/update-system.md) §4.6. **Check:** T0 picks the right release and asset from recorded responses.
3. **`download` and limits.** Follow at most 5 HTTPS redirects, and never send the token to a redirect host. V0–V6 run unchanged. Map rate limits to `providerRateLimited(retryAfter:)` as [update-system.md](../../02-design/update-system.md) §4.6 says. Logs use `io.apkrun.update`/`provider` with the host only. **Check:** the T1 rate-limit case passes.
4. **Fixtures and mock.** Record the responses in `Tests/Fixtures/update-repos/github/`: releases for V1 and V2 (V2 tagged `v0.1`), two assets with no ABI hint, a draft, a pre-release, assets with and without `digest`, and a rate-limit response. Add a GitHub REST mode to `scripts/dev/update-server.py` (Debug only). It serves these on `127.0.0.1` and honors `If-None-Match`. Create `apkrun-fixtures/helloupdate-releases` with the same releases. Verify whether real assets carry `digest`, and state the result in [update-system.md](../../02-design/update-system.md) §4.6. **Check:** the mock serves the recorded responses byte for byte.

**Tests.**
- T0 (`Packages/UpdateCore/Tests/UpdateCoreTests/`): asset choice, the `arm64`/`universal` preference, drafts, channels, `digest` parsing, rate-limit mapping, and cursor.
- T1: `GitHubProvider` against the REST mock: `304` on an unchanged ETag, rate limit, a redirect with no `Authorization`, and no token in settings, history, or logs.
- T2 (`Tests/IntegrationTests/`): V1 installed, provider pointed at the mock. The `v0.1` V2 release is installed, decided by its versionCode.
- T3 (nightly, network, `Tests/AcceptanceTests/`): against `apkrun-fixtures/helloupdate-releases`, V2 is detected and downloaded, and the test records whether `digest` is present.

**Done when.**
- The misleading tag `v0.1` on V2 does not matter: the correct APK is installed, decided by its versionCode.
- Two matching assets without an ABI hint give `ambiguousAsset(names)`.
- Drafts are never chosen. Pre-releases are chosen only on the `prerelease` channel.
- An asset found not newer is not downloaded again.
- With `digest`, V4 checks it. Without it, the history says "No checksum published".
- A rate limit gives `providerRateLimited(retryAfter:)`, and no request is made before the reset time.
- The token is stored only in the Keychain and sent to no host except `api.github.com`.

**Pitfalls.**
- Never forward `Authorization` across a redirect.
- Release JSON, notes, and asset names are untrusted. Show notes as plain text ([update-system.md](../../02-design/update-system.md) §12).
- Without `digest`, the V3 signer check is the only protection beyond TLS.
