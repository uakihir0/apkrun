# Direct Provider Manifest

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [schemas/direct-provider-manifest.schema.json](schemas/direct-provider-manifest.schema.json), [package-metadata-json.md](package-metadata-json.md) §2.4, [error-catalog.md](error-catalog.md), [../02-design/package-store.md](../02-design/package-store.md) §4, FR-UPD-12, FR-UPD-14 |

A distributor publishes this manifest over HTTPS. APKRun's `DirectProvider` (UpdateCore, #050) reads it to find a newer release of one Android package.

**Normative split.** The JSON Schema [schemas/direct-provider-manifest.schema.json](schemas/direct-provider-manifest.schema.json) (draft 2020-12) is normative for **structure**: field names, types, required fields, patterns, and numeric limits. This document is normative for **semantics**: URL resolution, rules the schema cannot express, how a reader uses each field, and which error each problem gives. When the two seem to disagree on structure, the schema wins and this document has a bug.

---

## 1. Overview

- One manifest describes one release of one package. It is a pointer. It is never a reason to trust an APK.
- The APK decides (FR-UPD-14). Manifest data can only cause a refusal, never an acceptance ([../02-design/update-system.md](../02-design/update-system.md) §12).
- The APK signer check (V3) protects the update. The declared `sha256` protects against corrupted or swapped downloads ([../02-design/update-system.md](../02-design/update-system.md) §4.4).
- The package's provider configuration holds the manifest URL (§8). APKRun polls that URL on the update schedule ([../02-design/update-system.md](../02-design/update-system.md) §3).

## 2. Complete example

A release with a base APK and two splits. The split URLs are relative to the manifest URL `https://downloads.example.com/app/manifest.json`.

```json
{
  "schemaVersion": 1,
  "packageId": "com.example.app",
  "versionCode": 45,
  "versionName": "4.5.0",
  "artifacts": [
    {
      "type": "apk",
      "url": "https://downloads.example.com/app/4.5.0/base.apk",
      "sha256": "3241729505a32a24e8acb966e0dcd2cbe17bf98885cda80d5590b242ba573ae6",
      "size": 51234567
    },
    {
      "type": "split",
      "splitName": "config.arm64_v8a",
      "url": "4.5.0/split_config.arm64_v8a.apk",
      "sha256": "47f37ce5990b785108363b3ce6be13cfe8c355f58cedadeb6de7338d9b54f0c9",
      "size": 18874368
    },
    {
      "type": "split",
      "splitName": "config.xxhdpi",
      "url": "4.5.0/split_config.xxhdpi.apk",
      "sha256": "55d897c4a5cc55cb6c68c6dc05f60c0b5b88017ca88bad3bfaf81622dd3b018f",
      "size": 2097152
    }
  ],
  "signingCertificates": [
    "sha256:06298432e8066b29e2223bcc23aa9504b56ae508fabf3435508869b9c3190e22"
  ],
  "minSdk": 29,
  "releaseNotes": "Faster startup.\nFixes a crash when sharing images.",
  "publishedAt": "2026-10-02T09:00:00Z"
}
```

The short form in [../02-design/update-system.md](../02-design/update-system.md) §4.4 (one `apk` artifact) is also valid.

## 3. Fields

### 3.1 Top level

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | exactly `1` | format version of the manifest (§9) |
| `packageId` | string | yes | two or more segments `[A-Za-z][A-Za-z0-9_]*` joined by `.`, at most 255 characters, case-sensitive | the Android package. Must equal the package the provider is attached to |
| `versionCode` | integer | yes | 1 to 9223372036854775807 | Android `longVersionCode` of the release (`versionCodeMajor` in the high 32 bits) |
| `versionName` | string | no | 1 to 255 characters | display only. Shown in the "update available" text before the download |
| `artifacts` | array of artifact (§3.2) | yes | 1 to 256 items, a valid combination (§4) | the files of the release |
| `signingCertificates` | array of string | no | 1 to 16 unique items, each `sha256:` + 64 lowercase hex | SHA-256 of each DER signing certificate of the release's signer set (the set Android uses on the guest SDK) |
| `minSdk` | integer | no | 1 to 10000 | declared `minSdkVersion`. A pre-filter only (§6.2 D9) |
| `releaseNotes` | string | no | plain text, at most 16384 characters and at most 16 KiB of UTF-8 | shown as text, never rendered as HTML |
| `publishedAt` | string | no | RFC 3339 `date-time` with a time zone | release time, shown in the update history |

Any other field is ignored (§9).

### 3.2 Artifact object

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `type` | string | yes | `apk`, `split`, or `apks` | `apk` = the base APK. `split` = one split APK. `apks` = a bundletool `.apks` container |
| `url` | string | yes | 1 to 2048 characters, a URI reference | absolute `https` URL, or a reference relative to the manifest URL. Must be `https` after resolution (§5.2) |
| `sha256` | string | yes | 64 hex digits, either case | SHA-256 of the file. Readers compare in lower case |
| `size` | integer | no | 1 to 8589934592 (8 GiB). For `apk` and `split`: at most 2147483648 (2 GiB) | size in bytes |
| `splitName` | string | only for `split` | segments `[A-Za-z][A-Za-z0-9_]*` joined by `.`, at most 255 characters. Forbidden for `apk` and `apks` | Android split name, for example `config.arm64_v8a` or `feature_camera` |

- The per-file limit of 2 GiB and the total of 8 GiB come from the store's intrinsic check I11 ([../02-design/package-store.md](../02-design/package-store.md) §4.6). The 8 GiB download cap is [../02-design/update-system.md](../02-design/update-system.md) §5.
- Every artifact needs `sha256` ([../02-design/update-system.md](../02-design/update-system.md) §4.4). A manifest without it is invalid. Direct downloads are never protected by TLS alone.

## 4. Artifact combinations

Exactly one of these shapes is valid. The schema enforces the shapes. The reader enforces the uniqueness rules.

| Shape | Artifacts | Extra rules |
|---|---|---|
| Single APK | one `apk` | — |
| Split set | one `apk` plus one or more `split` | `splitName` values are unique. Resolved URLs are unique |
| Container | one `apks` and nothing else | the container is extracted and its splits are selected as for a file import ([../02-design/package-store.md](../02-design/package-store.md) §4.2, §4.4) |

- `.xapk` and `.apkm` containers are not allowed in a Direct manifest. They are third-party formats. A distributor that controls its own manifest can publish plain APKs or `.apks`.
- For a split set, every listed file is downloaded. The downloaded set then goes through the store's split selection ([../02-design/package-store.md](../02-design/package-store.md) §4.4), so a distributor may list ABI or density splits the Mac does not need. Listing only what an arm64 guest needs saves download time.
- File names on disk come from the store (`base.apk`, `split_<splitName>.apk`), never from the URL ([../02-design/package-store.md](../02-design/package-store.md) §3.1).

## 5. Fetching

### 5.1 The manifest request

| Rule | Value |
|---|---|
| Scheme | `https`. Debug builds also accept `http://127.0.0.1` and `http://localhost` for the local test service of #050 |
| Conditional request | `If-None-Match` with the stored ETag, or `If-Modified-Since` with the stored `Last-Modified`. `304` → no candidate |
| Redirects | followed only to `https` URLs (or the debug loopback hosts above), at most 5 |
| Body size | at most 1 MiB. The reader stops at 1 MiB + 1 byte |
| Content type | not checked. The body must be UTF-8 JSON |
| Cursor | the response ETag. Without an ETag, `sha256:` + the SHA-256 of the body |

The HTTP client is UpdateCore's shared session ([../02-design/update-system.md](../02-design/update-system.md) §3.4). A `429` or `503` with `Retry-After` gives `providerRateLimited(retryAfter:)`. Any other non-2xx status gives `providerHTTPStatus(status)`. A network failure gives `providerUnreachable(detail:)`.

### 5.2 Artifact URLs

1. Resolve `url` against the **final** manifest URL (after redirects), with RFC 3986 reference resolution.
2. The result must be `https` (or a debug loopback URL as in §5.1). Otherwise the manifest is invalid.
3. The result must have no user info (`user:password@`). Credentials never go in a manifest.
4. The artifact download follows the redirect rule of §5.1.

### 5.3 Artifact downloads

- Each file is hashed while it streams. A download larger than the declared `size` is stopped at the first extra byte, and it counts as a hash mismatch.
- A hash mismatch retries once from scratch. A second mismatch gives `hashMismatch(file:)` ([../02-design/update-system.md](../02-design/update-system.md) §5).
- The sum of the downloads is capped at 8 GiB. Above it: `tooLarge(bytes:)`.

## 6. Validation rules

### 6.1 Structural

The body must parse as JSON and validate against [schemas/direct-provider-manifest.schema.json](schemas/direct-provider-manifest.schema.json). UpdateCore does this with a `Codable` model (`DirectManifest`) plus the semantic checks below. It does not load a JSON Schema engine at run time. The #050 T0 tests keep the model and the schema in agreement (§12).

### 6.2 Semantic (reader)

Checked in this order during `check`. Failures D1–D8 give `providerMetadataInvalid(detail:)`. The `detail` names the field and the rule, for example `artifacts[1].url: http is not allowed`.

| # | Rule |
|---|---|
| D1 | The body is at most 1 MiB and is valid UTF-8 JSON |
| D2 | `schemaVersion` is `1`. Another value gives the detail `unsupported schemaVersion <n>; update APKRun` |
| D3 | The schema validates (§6.1) |
| D4 | `packageId` equals the attached package, compared case-sensitively |
| D5 | Every artifact URL resolves to an allowed URL (§5.2) |
| D6 | `splitName` values are unique. Resolved artifact URLs are unique |
| D7 | The declared `size` values add up to at most 8 GiB |
| D8 | `releaseNotes` is at most 16 KiB as UTF-8 |
| D9 | `versionCode` ≤ the installed `longVersionCode` → no candidate (not an error). `minSdk` greater than the guest SDK → no candidate, and the check records `noCompatibleArtifact(.sdk)` |

- A failed check keeps the cursor of the last good response, so the manifest is fetched again at the next scheduled check. Three failures in a row raise the `updates.providers` warning ([../02-design/update-system.md](../02-design/update-system.md) §14).
- `signingCertificates` is **not** a check filter. A signer rotation makes the declared signer differ from the installed one, and V3 decides after the download.

### 6.3 After the download (validation pipeline)

The candidate then passes the whole pipeline V0–V6 ([../02-design/update-system.md](../02-design/update-system.md) §6). The manifest feeds these checks:

| Check | Manifest input | Failure |
|---|---|---|
| V0 (I1–I12) | the downloaded files | `validation(.intrinsic(StoreFailure))` |
| V1 | — (the APK's package against the installed package) | `validation(.packageMismatch(expected:found:))` |
| V2 | — (the APK's versionCode against the installed one) | `validation(.notNewer)` or `validation(.downgrade)` |
| V3 | — (APK signer continuity) | `validation(.signerMismatch)`, `validation(.lineageMissingCapability)` |
| V4 | `artifacts[].sha256` | `validation(.providerHashMismatch(file))` |
| V5 | `packageId`, `versionCode`, `signingCertificates` (as a set, when present) against the APK | `validation(.providerMetadataMismatch(field))`, with `field` = `packageId`, `versionCode`, or `signingCertificates` |
| V6 | `versionCode` against the skipped versions | `validation(.skippedVersion(versionCode))` |

`versionName`, `minSdk`, and `splitName` are not V5 fields. The APK's own values are used after the download.

## 7. Mapping to `UpdateCandidate`

| `UpdateCandidate` field ([../02-design/update-system.md](../02-design/update-system.md) §4.1) | From |
|---|---|
| `packageID` | `packageId` |
| `provider` | the attached `UpdateProviderRef` (`{"type":"direct","configuration":{"url":…}}`) |
| `declaredVersionCode` | `versionCode` |
| `declaredVersionName` | `versionName`, or nil |
| `declaredSignerDigests` | `signingCertificates`, or nil |
| `artifacts` | one `RemoteArtifact` per artifact: `url` = the resolved URL, `kind` = `.apk`, `.split(name: splitName)`, or `.container` for `apks`, `sha256` in lower case, `size` or nil |
| `releaseNotes` | `releaseNotes`, or nil |
| `publishedAt` | `publishedAt`, or nil |
| `cursor` | §5.1 |

## 8. Provider configuration

`ProviderConfiguration` for `type: direct` is `{url}`. It is stored in the package record ([package-metadata-json.md](package-metadata-json.md) §2.4).

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `url` | string | yes | absolute `https` URL, at most 2048 characters, no user info. Debug builds also accept `http://127.0.0.1[:port]` and `http://localhost[:port]` | the manifest URL |

- CLI spec: `direct:<https-url>`. The legacy alias `--update-provider direct --update-url <url>` means the same ([../02-design/update-system.md](../02-design/update-system.md) §11.3).
- `setUpdatePolicy` refuses a configuration that breaks these rules before it is stored. A stored configuration that breaks them (for example a release build reading a debug record) makes every check fail with `providerNotConfigured`.

## 9. Versioning rules

- `schemaVersion` is an integer. Only `1` is defined. A reader refuses any other value (D2).
- New **optional** fields that a v1 reader can ignore safely do not change `schemaVersion`. Readers ignore unknown fields at every level. This differs from APKRun's own data files ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5), because distributors publish this format and old APKRun versions must keep working.
- A change that a v1 reader would misread raises `schemaVersion`. Examples: a new required field, a new artifact `type`, or a field whose meaning changes. A distributor that needs both can publish two manifest URLs.
- A signed manifest (a detached signature with a key pinned when the provider is attached) is a v1.x candidate ([../04-plan/open-questions.md](../04-plan/open-questions.md)). It will be an optional companion file, so v1 readers are not affected.
- The schema file's `$id` carries the version: `urn:apkrun:schema:direct-provider-manifest:1`.

## 10. Writers and readers

| Role | Component | Notes |
|---|---|---|
| Writer | the distributor's release process | third party. Not trusted |
| Writer (tests) | `scripts/dev/update-server.py` (#050) | serves `Tests/Fixtures/update-repos/local/` as Direct manifests on `http://127.0.0.1:<port>`. Debug builds only |
| Reader | `DirectProvider` in UpdateCore (apkrund) | `check` (§5–§6.2), `download` (§5.3) |
| Reader (CI) | #050 T0 tests | validate the fixtures against the schema and decode them with the `Codable` model |

## 11. Security and logging

- Everything in the manifest is untrusted. The parser has the 1 MiB limit and is a fuzz target in #091.
- Release notes are plain text. They are never rendered as HTML and never logged.
- Logs (`io.apkrun.update`, category `provider`) show the provider type and host only. They never show full URLs with query strings, tokens, or release notes (NFR-SEC-05).
- No manifest field can turn off a check (NFR-SEC-04).

## 12. Tests and fixtures

| Tier | Test | Task |
|---|---|---|
| T0 | Schema and model: valid (single APK, split set, container), missing `sha256`, `http` URL, relative URL (valid, and one that resolves to `http`), oversized body, wrong package | #050 |
| T0 | Model and schema agree: every fixture that the schema accepts decodes, and every fixture it rejects fails with the expected D-rule | #050 |
| T1 | Local test service without a VM: `304`, redirects, the body cap, `429` with `Retry-After`, the cursor. A manifest whose `versionCode` disagrees with the APK is refused (V5). A wrong `sha256` fails the download with `hashMismatch(file:)` after one retry (§5.3; V4 catches only a file that changed after the download) | #050 |
| T2 | Local test service, custom image: HelloUpdate V1 → V2 installs, and V2 keeps V1's data | #050 |
| Fuzz | the manifest parser | #091 |

Fixtures live in `Tests/Fixtures/update-repos/direct/valid/*.json` and `Tests/Fixtures/update-repos/direct/invalid/*.json`. The fixture package is `io.apkrun.fixture.helloupdate`.
