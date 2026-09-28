# Package Metadata JSON (`metadata.json` and `settings.json`)

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [runtime-api.md](runtime-api.md) §4.2, §8.3, §9.2, [direct-provider-manifest.md](direct-provider-manifest.md) §8, [wrapper-json.md](wrapper-json.md), [error-catalog.md](error-catalog.md), [../02-design/diagnostics.md](../02-design/diagnostics.md) §6.2, [../02-design/desktop-integration.md](../02-design/desktop-integration.md) §2 |

APKStoreCore keeps two JSON files for every Android package that APKRun manages. `metadata.json` holds the `PackageRecord`: identity, versions, signers, update authority and provider, state, artifact slots, and the last known Android facts. `settings.json` holds the `PackageSettings`: the user's preferences for that package.

**Normative split.** The inline JSON Schemas (draft 2020-12, §2.6 and §3.4) are normative for **structure**: field names, types, required fields, patterns, and limits. This document is normative for **semantics**: rules across fields (§2.5), how each writer and reader uses a field, and what happens on errors. §3.1 is the authority for the package settings keys and defaults. [configuration.md](configuration.md) §3 defers to it.

---

## 1. Overview

### 1.1 Files

| File | Content | Swift type | `dataSchemas` key | Current `schemaVersion` | Writer |
|---|---|---|---|---|---|
| `Packages/<dir>/metadata.json` | the package record (§2) | `PackageRecord` | `packageRecord` | 1 | `PackageStore` (APKStoreCore in apkrund) |
| `Packages/<dir>/settings.json` | the package settings (§3) | `PackageSettings` | `packageSettings` | 1 | `PackageStore` |

- `<dir>` is the package ID. After a case collision it is `<packageId>~<first 8 hex of SHA-256(packageId)>` ([../02-design/package-store.md](../02-design/package-store.md) §3.2). Readers find a package by the record's `packageId`, never by the directory name.
- Every managed package has a `metadata.json`. The store writes `settings.json` together with the first record, even when it holds no key. A missing `settings.json` reads as `{"schemaVersion": 1}`: every key has its default. The next settings write creates the file.
- Unmanaged packages (installed in Android by something else, [../02-design/package-store.md](../02-design/package-store.md) §9.3) have neither file.
- Out of scope here: `artifact.json` in each slot (`ArtifactSet`, [../02-design/package-store.md](../02-design/package-store.md) §2.2, §3.3), the journal ([../02-design/package-store.md](../02-design/package-store.md) §5.1), and `Updates/state.json` ([../02-design/update-system.md](../02-design/update-system.md) §10.1). Skipped versions, cursors, and the update phase live in `Updates/state.json`, not in the record.

### 1.2 Encoding

- One UTF-8 JSON object. `JSONEncoder` with `.sortedKeys`, `.prettyPrinted`, and `.withoutEscapingSlashes`, plus a trailing newline. This is the same encoding as `wrapper.json` ([../02-design/wrapper.md](../02-design/wrapper.md) §3).
- Size limits: `metadata.json` at most 64 KiB, `settings.json` at most 16 KiB. A larger file is treated as unreadable (§4.2).
- The examples in this document have sorted keys. Their whitespace is illustrative.
- Values follow the DTO rules of [runtime-api.md](runtime-api.md) §4.2. The record in `PackageDetails.record` (`WirePackageRecord`, [runtime-api.md](runtime-api.md) §8.3) is therefore the same JSON, with the differences listed in §2.3.1 and §2.3.5.
  - Keys are the Swift property names, lowerCamelCase.
  - An enum without payload is its case name as a string: `"installed"`.
  - An enum with payload is an object with one key, the case name. Unlabeled payloads use `_0`: `{"broken": {"_0": "removedInAndroid"}}`.
  - Optional values are omitted when nil. These files never contain `null`.
  - Dates are ISO 8601 UTC. Writers write milliseconds and `Z` (`2026-10-02T09:12:09.020Z`). Readers also accept a date without fractional seconds.
- `PackageState` mixes cases with and without payload. Swift's synthesized `Codable` would write `{"installed": {}}` for such an enum. `PackageState` and `WirePackageState` therefore have a hand-written `Codable` that produces the forms of §2.3.1.

### 1.3 Common value types

| Type | JSON | Rule | Source |
|---|---|---|---|
| `PackageID` | string | two or more dot-separated segments of `[A-Za-z][A-Za-z0-9_]*`, at most 255 characters, case-sensitive | [../02-design/package-store.md](../02-design/package-store.md) §2.1 |
| `VersionCode` | integer | `Int64`, at least 0. It includes `versionCodeMajor` (the long version code) | [../02-design/package-store.md](../02-design/package-store.md) §2.1 |
| `SHA256Digest` | string | `"sha256:"` + 64 lowercase hex characters | [runtime-api.md](runtime-api.md) §4.3 |
| `Date` | string | §1.2 | [runtime-api.md](runtime-api.md) §4.2 |
| `OperationID` | string | lowercase UUID | [runtime-api.md](runtime-api.md) §4.3 |
| `UUID` | string | lowercase UUID (`userdataGeneration`) | [../02-design/package-store.md](../02-design/package-store.md) §9.2 |
| `StoredError` | object | a `WireError` without `context` (§2.3.6) | [runtime-api.md](runtime-api.md) §4.5 |

---

## 2. Package record (`metadata.json`)

### 2.1 Complete example

An `apkrun` package with a Direct provider. Version 45 is installed. Version 44 is in `previous/`, and version 46 is staged.

```json
{
  "android": {
    "firstInstallTime": "2026-09-20T14:03:11.000Z",
    "installerOfRecord": "io.apkrun.store",
    "lastSyncedAt": "2026-10-02T09:12:10.020Z",
    "lastUpdateTime": "2026-10-02T09:12:08.000Z",
    "minSdk": 26,
    "nativeAbis": [
      "arm64-v8a"
    ],
    "targetSdk": 35,
    "updateOwner": "io.apkrun.store",
    "userdataGeneration": "622ec21f-5ab6-4077-8b13-293c025adcfb"
  },
  "artifacts": {
    "current": {
      "fileCount": 2,
      "setDigest": "sha256:96bbfcf3145dec90d6fcfbce72677d07cda54ef74eb0e14c6364ba79a92768ad",
      "size": 48213377,
      "versionCode": 45,
      "versionName": "4.5"
    },
    "currentMatchesAndroid": true,
    "previous": {
      "fileCount": 2,
      "setDigest": "sha256:0ba5957d14f5980cb5c3f7c87e397b7a2459190db272a67cc5c987ac6d2c8340",
      "size": 47990012,
      "versionCode": 44,
      "versionName": "4.4"
    },
    "staged": {
      "fileCount": 1,
      "origin": {
        "declaredDigests": [
          "sha256:289d4f633b49cdd40870cb597196fb715ba82fdbd8292bac2049953102e0a357"
        ],
        "type": "direct",
        "url": "https://downloads.example.org/notes/notes-4.6.apk"
      },
      "setDigest": "sha256:a125cccab0210153d215ec619a654df8886c74d9a6cb1d848c7981eb5d964412",
      "size": 48520007,
      "versionCode": 46,
      "versionName": "4.6"
    }
  },
  "createdAt": "2026-09-20T14:03:12.410Z",
  "displayName": "Notes",
  "installer": "apkrun",
  "lastOperation": {
    "finishedAt": "2026-10-02T09:13:40.500Z",
    "fromVersionCode": 44,
    "healthResult": "passed",
    "kind": "update",
    "operationID": "35765f40-330c-4fe6-888c-e70de392b247",
    "result": "succeeded",
    "startedAt": "2026-10-02T09:12:03.120Z",
    "toVersionCode": 45
  },
  "packageId": "org.example.notes",
  "schemaVersion": 1,
  "signingCertificates": [
    "sha256:d43041c5c08759aeb0aa94c1bb854186b4ab1512364f8dc5c1150ae176e3ec56"
  ],
  "signingLineage": [],
  "source": {
    "at": "2026-09-20T14:02:58.000Z",
    "container": "apk",
    "fileNames": [
      "notes-4.3.apk"
    ],
    "kind": "file",
    "origin": "addFlow"
  },
  "state": "installed",
  "updateAuthority": "apkrun",
  "updateProvider": {
    "configuration": {
      "url": "https://downloads.example.org/notes/manifest.json"
    },
    "type": "direct"
  },
  "updatedAt": "2026-10-02T09:20:01.007Z",
  "versionCode": 45,
  "versionName": "4.5"
}
```

An adopted package ([../02-design/package-store.md](../02-design/package-store.md) §9.3). It has no artifact, no provider, and no file source:

```json
{
  "android": {
    "firstInstallTime": "2026-08-30T10:00:00.000Z",
    "installerOfRecord": "com.android.shell",
    "lastSyncedAt": "2026-10-01T08:00:02.310Z",
    "lastUpdateTime": "2026-08-30T10:00:00.000Z",
    "minSdk": 24,
    "nativeAbis": [],
    "targetSdk": 34,
    "userdataGeneration": "622ec21f-5ab6-4077-8b13-293c025adcfb"
  },
  "artifacts": {
    "currentMatchesAndroid": false
  },
  "createdAt": "2026-10-01T08:00:02.310Z",
  "displayName": "Chat",
  "installer": "external",
  "lastOperation": {
    "finishedAt": "2026-10-01T08:00:02.310Z",
    "kind": "adopt",
    "operationID": "d783ff6b-b9cb-418f-919b-83462646381d",
    "result": "succeeded",
    "startedAt": "2026-10-01T08:00:01.950Z",
    "toVersionCode": 3120
  },
  "packageId": "com.example.chat",
  "schemaVersion": 1,
  "signingCertificates": [
    "sha256:c07000f33afeca8af1aeff0de3de6ca0179be64d7546c267d51e4ca5d23f82f2"
  ],
  "signingLineage": [],
  "source": {
    "at": "2026-10-01T08:00:01.950Z",
    "kind": "adopted"
  },
  "state": "installed",
  "updateAuthority": "external",
  "updatedAt": "2026-10-01T08:00:02.310Z",
  "versionCode": 3120,
  "versionName": "3.12"
}
```

### 2.2 Top-level fields

The field names are those of [../02-design/package-store.md](../02-design/package-store.md) §2.3, which keeps 's names.

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | `1` | the schema of this file (§5) |
| `packageId` | `PackageID` | yes | §1.3 | the Android package name. It never changes for a record |
| `displayName` | string | yes | 1–1024 characters | Android's label in the guest locale ([../02-design/package-store.md](../02-design/package-store.md) §10.3). Before the first install, the host preview label. A longer label is cut at a grapheme boundary |
| `versionCode` | `VersionCode` | yes | §1.3 | what Android reports as installed. For `uninstalledKeepingData`, the version that was installed at the uninstall |
| `versionName` | string | no | 1–1024 characters | Android's `versionName`. Omitted when the package has none |
| `signingCertificates` | array of `SHA256Digest` | yes | 1–16 items, unique, sorted ascending | the current signer set, as Android reports it after the install |
| `signingLineage` | array of `SHA256Digest` | yes | 0–16 items, unique, oldest → newest. Empty without key rotation | the signing lineage. When it is not empty, its last item is in `signingCertificates` |
| `installer` | enum | yes | `apkrun`, `external` | who installed the package into Android. `external` only for adopted packages ([../02-design/package-store.md](../02-design/package-store.md) §9.3) |
| `updateAuthority` | enum | yes | `apkrun`, `googlePlay`, `external`, `manual` | who updates the package (ADR-0010, [../02-design/update-system.md](../02-design/update-system.md) §2.1). `googlePlay` is post-v1 (#097). v1 writers never write it, and v1 readers accept it |
| `updateProvider` | object | no | §2.4 | the attached update provider. Omitted when there is none |
| `state` | `PackageState` | yes | a persisted state (§2.3.1) | the package state ([../01-architecture/state-machines.md](../01-architecture/state-machines.md) §5) |
| `artifacts` | object | yes | §2.3.2 | summaries of the artifact slots |
| `android` | object | yes | §2.3.3 | the last known Android facts |
| `source` | object | yes | §2.3.4 | how the package first arrived |
| `lastOperation` | object | no | §2.3.5 | the result of the last operation, for the UI and `apkrun doctor` |
| `createdAt` | `Date` | yes | | when the record was first written |
| `updatedAt` | `Date` | yes | ≥ `createdAt` | the last write of this file |

### 2.3 Nested objects

#### 2.3.1 `state`

A record file holds only the states that last beyond one operation:

| State | JSON |
|---|---|
| `installed` | `"installed"` |
| `uninstalledKeepingData` | `"uninstalledKeepingData"` |
| `needsReinstall(.userdataReset)` | `{"needsReinstall": {"_0": "userdataReset"}}` |
| `needsReinstall(.userdataRestored)` | `{"needsReinstall": {"_0": "userdataRestored"}}` |
| `broken(.removedInAndroid)` | `{"broken": {"_0": "removedInAndroid"}}` |
| `broken(.signerChanged)` | `{"broken": {"_0": "signerChanged"}}` |
| `broken(.artifactMissing)` | `{"broken": {"_0": "artifactMissing"}}` |
| `broken(.reinstallFailed(error))` | `{"broken": {"_0": {"reinstallFailed": {"_0": <StoredError>}}}}` |

- `importing`, `inspecting`, `installing`, `updating(_)`, and `uninstalling` exist only while a transaction or an UpdateCore flow runs. The store derives them from its open transactions and from UpdateCore when it publishes a record. They are never written. After a crash, recovery decides the state ([../02-design/package-store.md](../02-design/package-store.md) §5.5).
- `WirePackageState` ([runtime-api.md](runtime-api.md) §8.3) uses the same encoding. It adds the transient states and `unknown`, and its `reinstallFailed` payload is a full `WireError`.

An example of the last row, after three failed reinstalls on consecutive boots:

```json
{
  "broken": {
    "_0": {
      "reinstallFailed": {
        "_0": {
          "code": "store.guestStorageFull",
          "domain": "store",
          "parameters": {}
        }
      }
    }
  }
}
```

#### 2.3.2 `artifacts`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `current` | slot summary | no | required while `installer` is `apkrun` and `state` is not `uninstalledKeepingData` | the set in `current/`, what Android should have installed |
| `previous` | slot summary | no | only with `current`. `versionCode` lower than `current`'s | the last known-good set in `previous/` |
| `staged` | staged slot summary | no | only with `current`. `versionCode` higher than the top-level `versionCode` | a verified update in `staged/` ([../02-design/package-store.md](../02-design/package-store.md) §7.1) |
| `currentMatchesAndroid` | boolean | yes | `false` when `current` is absent | whether Android's installed version is the set in `current/`. `false` after someone else updated the package ([../02-design/package-store.md](../02-design/package-store.md) §9.2) |

Slot summary. The values are copied from the slot's `artifact.json` when the slot is filled:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `versionCode` | `VersionCode` | yes | | the set's version |
| `versionName` | string | no | 1–1024 characters | for "Roll Back to ‹version›" without reading `artifact.json` |
| `setDigest` | `SHA256Digest` | yes | unique across the three slots | the set digest ([../02-design/package-store.md](../02-design/package-store.md) §3.3) |
| `size` | integer | yes | 1 to 8 GiB (8589934592) | the sum of the file sizes in bytes |
| `fileCount` | integer | yes | 1–256 | the number of APK files (base plus splits) |

A staged slot summary has the fields of a slot summary plus `origin`:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `origin.type` | enum | yes | `local`, `direct`, `fdroid`, `github`, `manualFile` | where the candidate came from. `manualFile` is a user-supplied file for an installed package ([../02-design/update-system.md](../02-design/update-system.md) §5) |
| `origin.url` | string | no | absolute `https` URL, at most 2048 characters, without user info, query, or fragment | the download URL of the first artifact. Omitted for `local` and `manualFile`. Query and fragment are removed before storing |
| `origin.declaredDigests` | array of `SHA256Digest` | no | 1–256 items | the SHA-256 values the provider declared, in artifact order. Omitted when the provider declared none |

#### 2.3.3 `android`

The facts come from `GetPackageMetadata` (or `QueryPackage` on stock images). The guest protocol field is given in parentheses.

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `updateOwner` | string | no | `PackageID` | the update owner (`update_owner`). Omitted when the package has none ([../02-design/package-store.md](../02-design/package-store.md) §6.3) |
| `installerOfRecord` | string | no | `PackageID` | the installing package (`installer_of_record`). `io.apkrun.store` for Store Agent installs |
| `firstInstallTime` | `Date` | no | | `first_install_time_ms` |
| `lastUpdateTime` | `Date` | no | | `last_update_time_ms`. Recovery compares it with a transaction's `begin` ([../02-design/package-store.md](../02-design/package-store.md) §5.5) |
| `minSdk` | integer | yes | 1–10000 | `min_sdk` |
| `targetSdk` | integer | yes | 1–10000 | `target_sdk` |
| `nativeAbis` | array of string | yes | 0–8 unique items, each `^[a-z0-9_-]{1,32}$` | `native_abis`. Empty when the package has no native code |
| `userdataGeneration` | `UUID` | yes | | the `userdata.img` generation from `instance.json` that the package was installed or adopted into ([../02-design/package-store.md](../02-design/package-store.md) §9.2) |
| `lastSyncedAt` | `Date` | yes | | the last time these facts were read from Android |

Before the first contact with Android (a first install on a stock image that returned no metadata yet), `minSdk`, `targetSdk`, and `nativeAbis` come from the host inspection.

#### 2.3.4 `source`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `kind` | enum | yes | `file`, `provider`, `wrapperBootstrap`, `adopted` | how the package first arrived on this Mac ([../02-design/package-store.md](../02-design/package-store.md) §2.3) |
| `at` | `Date` | yes | ≤ `createdAt` | when the import or adoption started |
| `origin` | enum | no | `addFlow`, `document`, `dropOnHome`, `cli`, `wrap`. Only with `kind` `file` | the `ImportOrigin` of the import ([runtime-api.md](runtime-api.md) §8.2) |
| `fileNames` | array of string | no | 1–20 items, each 1–255 characters without `/`. Only with `kind` `file` | the last path components of the user's files ([../02-design/package-store.md](../02-design/package-store.md) §3.1). Never a full path |
| `container` | enum | no | `apk`, `apks`, `xapk`, `apkm`, `zip`. Only with `kind` `file` or `provider` | the detected container ([../02-design/package-store.md](../02-design/package-store.md) §4.2) |
| `providerType` | enum | no | `local`, `direct`, `fdroid`, `github`. Required with `kind` `provider`, absent otherwise | the provider that delivered the first install |
| `wrapperBundleId` | string | no | `^io\.apkrun\.android\.[A-Za-z0-9.-]+$`, at most 255 characters. Required with `kind` `wrapperBootstrap`, absent otherwise | the portable wrapper that carried the bootstrap ([../02-design/wrapper.md](../02-design/wrapper.md) §10.2) |

`source` is written once and never changes. Later changes of authority or provider do not touch it.

#### 2.3.5 `lastOperation` (`OperationSummary`)

This is the definition of `OperationSummary`, which [../02-design/package-store.md](../02-design/package-store.md) §2.3 and [runtime-api.md](runtime-api.md) §8.3 use.

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `kind` | enum | yes | `firstInstall`, `reinstall`, `update`, `rollback`, `uninstall`, `adopt` | the operation. Repair is a `reinstall` |
| `operationID` | `OperationID` | yes | | the operation's ID ([../02-design/diagnostics.md](../02-design/diagnostics.md) §2.4) |
| `startedAt` | `Date` | yes | | when it started |
| `finishedAt` | `Date` | yes | ≥ `startedAt` | when it ended |
| `fromVersionCode` | `VersionCode` | no | only for `reinstall`, `update`, `rollback` | the version before |
| `toVersionCode` | `VersionCode` | no | | the target version |
| `result` | enum | yes | `succeeded`, `failed`, `interrupted`, `rollbackUnavailable` | `interrupted`: recovery aborted it ("Installing ‹App› was interrupted", [../02-design/package-store.md](../02-design/package-store.md) §5.5). `rollbackUnavailable`: only for `rollback`, a background rollback that needed the data-loss fallback ([../02-design/package-store.md](../02-design/package-store.md) §7.3) |
| `healthPending` | boolean | no | `true` only. Only for `update` with `result` `succeeded` | the post-update health check has not been recorded yet ([../02-design/package-store.md](../02-design/package-store.md) §7.2). UpdateCore runs it after a restart ([../02-design/update-system.md](../02-design/update-system.md) §10.1) |
| `healthResult` | enum | no | `passed`, `failed`. Only for `update` with `result` `succeeded`, and never with `healthPending` | what `recordHealth` recorded |
| `failureCount` | integer | no | 1–1000. Required when `result` is `failed`, absent otherwise | consecutive failures of the same kind for the same `toVersionCode`. The third failed boot reinstall moves the package to `broken(.reinstallFailed)` |
| `error` | `StoredError` | no | only when `result` is `failed` or `rollbackUnavailable` | the failure (§2.3.6) |
| `pending` | boolean | no | never written to `metadata.json` | only in the published record: post-boot work is pending ([../02-design/package-store.md](../02-design/package-store.md) §5.4 step 6) |

- Booleans that can only be `true` are omitted instead of being written as `false`. Readers treat `false` like an absent field.
- `pending` is an overlay. The store sets it when it publishes records at `open`. The file keeps the last finished operation.

#### 2.3.6 `StoredError`

A stored error is a `WireError` ([runtime-api.md](runtime-api.md) §4.5) without `context`:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `domain` | string | yes | an error domain ([error-catalog.md](error-catalog.md) §2.1) | `store`, `update`, … |
| `code` | string | yes | `<domain>.<case>` | the qualified code, for example `store.guestStorageFull` |
| `parameters` | object | yes | at most 16 entries. Each value is a one-key object `text`, `bytes`, `count`, `durationMs`, or `fileName` with an `_0` payload | the message parameters. Text values are at most 1024 characters |
| `cause` | `StoredError` | no | nesting depth at most 4 | a nested error |
| `underlying` | object | no | `{domain: string, code: integer}` | the system error, without `userInfo` |

Stored errors never contain a full path or a URL with a query ([../02-design/diagnostics.md](../02-design/diagnostics.md) §3.2, §6).

### 2.4 `updateProvider` and `ProviderConfiguration`

`updateProvider` is an `UpdateProviderRef` ([../02-design/update-system.md](../02-design/update-system.md) §4.1):

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `type` | enum | yes | `local`, `direct`, `fdroid`, `github` | the provider (`ProviderType`) |
| `configuration` | object | yes | the object for `type`, below | the `ProviderConfiguration` |

- `configuration` is a plain object with the fields of its type. It is not wrapped in an enum object, because `type` already names the case.
- Only these fields are stored. The GitHub token lives in the Keychain (service `io.apkrun.provider.github`) and never in this file, `settings.json`, or logs ([../02-design/update-system.md](../02-design/update-system.md) §4.6).
- `setUpdatePolicy` parses the CLI spec (`ProviderSpec.spec`, [runtime-api.md](runtime-api.md) §9.2) into these fields. It fills in defaults, normalizes values, and validates them before anything is written. For F-Droid and GitHub it also makes one test request. A failure writes nothing.

**Local** (`type: local`, #037). For tests and development. Hidden in the UI unless developer mode is on ([../02-design/update-system.md](../02-design/update-system.md) §4.3).

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `path` | string | yes | an absolute POSIX path, at most 1024 UTF-8 bytes, no `.` or `..` components | the provider root that holds `<packageId>/<versionCode>/`. For display and logs at `debug` level only |
| `bookmark` | string | yes | Base64 of security-scoped bookmark data, at most 8 KiB after decoding | how apkrund opens the root. apkrund never opens `path` itself ([runtime-api.md](runtime-api.md) §9.2) |

CLI spec `local:<path>`. The CLI makes the path absolute and creates the bookmark.

**Direct** (`type: direct`, #050). The rules are in [direct-provider-manifest.md](direct-provider-manifest.md) §8:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `url` | string | yes | absolute `https` URL, at most 2048 characters, no user info. Debug builds also accept `http://127.0.0.1[:port]` and `http://localhost[:port]` | the manifest URL |

CLI spec `direct:<https-url>`, and the legacy alias `--update-provider direct --update-url <url>`.

**F-Droid** (`type: fdroid`, #051, [../02-design/update-system.md](../02-design/update-system.md) §4.5):

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `repository` | string | yes | absolute `https` URL, at most 2048 characters, no user info, query, or fragment, no trailing `/`. Debug builds also accept `http://127.0.0.1[:port]` and `http://localhost[:port]` (the F-Droid mode of the test server, #051) | the repository base. The index is `<repository>/entry.jar` |
| `fingerprint` | string | yes | 64 lowercase hex characters | the SHA-256 fingerprint of the repository's signing certificate |

- CLI spec `fdroid[:<repository-url>#<fingerprint>]`. Plain `fdroid` means the main repository `https://f-droid.org/repo` with the fingerprint pinned in the app (`43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab`, to be verified in #051).
- Both fields are stored explicitly, also for the main repository. A later change of the built-in default does not change existing records.
- The parser removes spaces and `:` from a fingerprint and lowercases it.

**GitHub** (`type: github`, #052, [../02-design/update-system.md](../02-design/update-system.md) §4.6):

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `repository` | string | yes | `owner/name`. `owner`: `^[A-Za-z0-9][A-Za-z0-9-]{0,38}$`. `name`: `^[A-Za-z0-9._-]{1,100}$`, not `.` or `..` | the repository |
| `assetPattern` | string | yes | 1–255 characters, no `/` | the glob for the release asset. Default `*.apk` |
| `channel` | enum | yes | `stable`, `prerelease` | `prerelease` also considers pre-releases. Default `stable` |

CLI spec `github:<owner>/<name>[:<asset-glob>][@prerelease]`. All three fields are stored, with the defaults filled in.

Rules for all providers:

- A provider is attached only to an `apkrun` package. Attaching one to a `manual` package makes it `apkrun`. Detaching it makes the package `manual` ([../02-design/update-system.md](../02-design/update-system.md) §2.1).
- The UI choice **Manual** keeps the provider, unused, so switching back restores it ([../02-design/update-system.md](../02-design/update-system.md) §2.3). A `manual` record can therefore have `updateProvider`.
- `googlePlay` and `external` records never have a provider.
- A reader that finds a configuration that breaks these rules keeps the record readable. Every check of that package then fails with `update.providerNotConfigured` until the user sets a new provider. Examples: a release build that reads a debug `http` URL, or an unknown field.
- Diagnostics and logs show the provider type and the host only ([../02-design/diagnostics.md](../02-design/diagnostics.md) §6.2). `path`, `bookmark`, the URL path, the repository name, and the asset pattern are left out.

### 2.5 Invariants

The store checks these rules before every write (§4.1). The schema of §2.6 encodes the rules marked "schema". The others are checked in code by `PackageRecordValidator`.

| # | Rule | Check |
|---|---|---|
| R1 | `installer` `external` ⇒ `updateAuthority` is `external`, `googlePlay`, or `manual`, there is no `updateProvider`, and `artifacts.current` is absent | schema |
| R2 | `updateAuthority` `apkrun` ⇒ `installer` is `apkrun` and `updateProvider` is present | schema |
| R3 | `updateAuthority` `googlePlay` or `external` ⇒ no `updateProvider` | schema |
| R4 | `source.kind` `adopted` ⇒ `installer` `external`, until APKRun installs a file for the package. Then `installer` becomes `apkrun`, and `source` stays `adopted` | code |
| R5 | `state` `uninstalledKeepingData` ⇒ no `current`, `previous`, or `staged` | schema |
| R6 | `installer` `apkrun` and `state` not `uninstalledKeepingData` ⇒ `artifacts.current` is present | schema |
| R7 | `state` `needsReinstall(_)` ⇒ `installer` `apkrun`. An adopted package becomes `broken(.removedInAndroid)` instead ([../02-design/package-store.md](../02-design/package-store.md) §9.3) | schema |
| R8 | `previous.versionCode` < `current.versionCode`, and `staged.versionCode` > the top-level `versionCode` | code |
| R9 | the `setDigest` values of the slots are distinct | code |
| R10 | `artifacts.currentMatchesAndroid` ⇒ `current` is present and `current.versionCode` equals the top-level `versionCode` | code |
| R11 | `createdAt` ≤ `updatedAt`, and `source.at` ≤ `createdAt` | code |
| R12 | the last item of a non-empty `signingLineage` is in `signingCertificates` | code |
| R13 | `configuration` matches `type` (§2.4) | schema |
| R14 | `lastOperation.healthPending` and `healthResult` only for `kind` `update` with `result` `succeeded`, and not both | code |
| R15 | `lastOperation.failureCount` is present exactly when `result` is `failed` | code |

"Adopt Android's version" for `broken(.signerChanged)` makes the record `installer` `external` and `updateAuthority` `external`. The slots are deleted, because APKRun's set no longer matches Android's signer.

### 2.6 JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:package-record:1",
  "title": "APKRun package record (Packages/<dir>/metadata.json), schemaVersion 1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion",
    "packageId",
    "displayName",
    "versionCode",
    "signingCertificates",
    "signingLineage",
    "installer",
    "updateAuthority",
    "state",
    "artifacts",
    "android",
    "source",
    "createdAt",
    "updatedAt"
  ],
  "properties": {
    "schemaVersion": {
      "const": 1
    },
    "packageId": {
      "$ref": "#/$defs/packageId"
    },
    "displayName": {
      "$ref": "#/$defs/label"
    },
    "versionCode": {
      "$ref": "#/$defs/versionCode"
    },
    "versionName": {
      "$ref": "#/$defs/label"
    },
    "signingCertificates": {
      "type": "array",
      "minItems": 1,
      "maxItems": 16,
      "uniqueItems": true,
      "items": {
        "$ref": "#/$defs/sha256Digest"
      }
    },
    "signingLineage": {
      "type": "array",
      "maxItems": 16,
      "uniqueItems": true,
      "items": {
        "$ref": "#/$defs/sha256Digest"
      }
    },
    "installer": {
      "enum": [
        "apkrun",
        "external"
      ]
    },
    "updateAuthority": {
      "enum": [
        "apkrun",
        "googlePlay",
        "external",
        "manual"
      ]
    },
    "updateProvider": {
      "$ref": "#/$defs/updateProvider"
    },
    "state": {
      "$ref": "#/$defs/state"
    },
    "artifacts": {
      "$ref": "#/$defs/artifacts"
    },
    "android": {
      "$ref": "#/$defs/android"
    },
    "source": {
      "$ref": "#/$defs/source"
    },
    "lastOperation": {
      "$ref": "#/$defs/operationSummary"
    },
    "createdAt": {
      "$ref": "#/$defs/date"
    },
    "updatedAt": {
      "$ref": "#/$defs/date"
    }
  },
  "allOf": [
    {
      "if": {
        "properties": {
          "installer": {
            "const": "external"
          }
        }
      },
      "then": {
        "properties": {
          "updateAuthority": {
            "enum": [
              "external",
              "googlePlay",
              "manual"
            ]
          },
          "artifacts": {
            "not": {
              "required": [
                "current"
              ]
            }
          }
        },
        "not": {
          "required": [
            "updateProvider"
          ]
        }
      }
    },
    {
      "if": {
        "properties": {
          "updateAuthority": {
            "const": "apkrun"
          }
        }
      },
      "then": {
        "required": [
          "updateProvider"
        ],
        "properties": {
          "installer": {
            "const": "apkrun"
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "updateAuthority": {
            "enum": [
              "googlePlay",
              "external"
            ]
          }
        }
      },
      "then": {
        "not": {
          "required": [
            "updateProvider"
          ]
        }
      }
    },
    {
      "if": {
        "properties": {
          "state": {
            "const": "uninstalledKeepingData"
          }
        }
      },
      "then": {
        "properties": {
          "artifacts": {
            "not": {
              "anyOf": [
                {
                  "required": [
                    "current"
                  ]
                },
                {
                  "required": [
                    "previous"
                  ]
                },
                {
                  "required": [
                    "staged"
                  ]
                }
              ]
            }
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "installer": {
            "const": "apkrun"
          },
          "state": {
            "not": {
              "const": "uninstalledKeepingData"
            }
          }
        }
      },
      "then": {
        "properties": {
          "artifacts": {
            "required": [
              "current"
            ]
          }
        }
      }
    },
    {
      "if": {
        "properties": {
          "state": {
            "type": "object",
            "required": [
              "needsReinstall"
            ]
          }
        }
      },
      "then": {
        "properties": {
          "installer": {
            "const": "apkrun"
          }
        }
      }
    }
  ],
  "$defs": {
    "packageId": {
      "type": "string",
      "maxLength": 255,
      "pattern": "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"
    },
    "versionCode": {
      "type": "integer",
      "minimum": 0,
      "maximum": 9223372036854775807
    },
    "sha256Digest": {
      "type": "string",
      "pattern": "^sha256:[0-9a-f]{64}$"
    },
    "date": {
      "type": "string",
      "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$"
    },
    "uuid": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
    },
    "label": {
      "type": "string",
      "minLength": 1,
      "maxLength": 1024
    },
    "httpsURL": {
      "type": "string",
      "maxLength": 2048,
      "pattern": "^https://[^/?#@\\s]+(/[^?#\\s]*)?$"
    },
    "providerType": {
      "enum": [
        "local",
        "direct",
        "fdroid",
        "github"
      ]
    },
    "updateProvider": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "type",
        "configuration"
      ],
      "properties": {
        "type": {
          "$ref": "#/$defs/providerType"
        },
        "configuration": {
          "type": "object"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "type": {
                "const": "local"
              }
            }
          },
          "then": {
            "properties": {
              "configuration": {
                "$ref": "#/$defs/localConfiguration"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "direct"
              }
            }
          },
          "then": {
            "properties": {
              "configuration": {
                "$ref": "#/$defs/directConfiguration"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "fdroid"
              }
            }
          },
          "then": {
            "properties": {
              "configuration": {
                "$ref": "#/$defs/fdroidConfiguration"
              }
            }
          }
        },
        {
          "if": {
            "properties": {
              "type": {
                "const": "github"
              }
            }
          },
          "then": {
            "properties": {
              "configuration": {
                "$ref": "#/$defs/githubConfiguration"
              }
            }
          }
        }
      ]
    },
    "localConfiguration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "path",
        "bookmark"
      ],
      "properties": {
        "path": {
          "type": "string",
          "minLength": 2,
          "maxLength": 1024,
          "pattern": "^/(?!.*(^|/)\\.\\.?(/|$)).*$"
        },
        "bookmark": {
          "type": "string",
          "minLength": 4,
          "maxLength": 10924,
          "pattern": "^[A-Za-z0-9+/]+={0,2}$"
        }
      }
    },
    "directConfiguration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "url"
      ],
      "properties": {
        "url": {
          "type": "string",
          "maxLength": 2048,
          "pattern": "^(https://[^/?#@\\s]+|http://(127\\.0\\.0\\.1|localhost)(:[0-9]{1,5})?)([/?#][^\\s]*)?$"
        }
      }
    },
    "fdroidConfiguration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "repository",
        "fingerprint"
      ],
      "properties": {
        "repository": {
          "type": "string",
          "maxLength": 2048,
          "pattern": "^(https://[^/?#@\\s]+|http://(127\\.0\\.0\\.1|localhost)(:[0-9]{1,5})?)(/[^?#\\s]*)?$",
          "not": {
            "pattern": "/$"
          }
        },
        "fingerprint": {
          "type": "string",
          "pattern": "^[0-9a-f]{64}$"
        }
      }
    },
    "githubConfiguration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "repository",
        "assetPattern",
        "channel"
      ],
      "properties": {
        "repository": {
          "type": "string",
          "pattern": "^[A-Za-z0-9][A-Za-z0-9-]{0,38}/(?!\\.\\.?$)[A-Za-z0-9._-]{1,100}$"
        },
        "assetPattern": {
          "type": "string",
          "minLength": 1,
          "maxLength": 255,
          "pattern": "^[^/]+$"
        },
        "channel": {
          "enum": [
            "stable",
            "prerelease"
          ]
        }
      }
    },
    "state": {
      "oneOf": [
        {
          "enum": [
            "installed",
            "uninstalledKeepingData"
          ]
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "needsReinstall"
          ],
          "properties": {
            "needsReinstall": {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "_0"
              ],
              "properties": {
                "_0": {
                  "enum": [
                    "userdataReset",
                    "userdataRestored"
                  ]
                }
              }
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "broken"
          ],
          "properties": {
            "broken": {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "_0"
              ],
              "properties": {
                "_0": {
                  "$ref": "#/$defs/brokenReason"
                }
              }
            }
          }
        }
      ]
    },
    "brokenReason": {
      "oneOf": [
        {
          "enum": [
            "removedInAndroid",
            "signerChanged",
            "artifactMissing"
          ]
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "reinstallFailed"
          ],
          "properties": {
            "reinstallFailed": {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "_0"
              ],
              "properties": {
                "_0": {
                  "$ref": "#/$defs/storedError"
                }
              }
            }
          }
        }
      ]
    },
    "storedError": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "domain",
        "code",
        "parameters"
      ],
      "properties": {
        "domain": {
          "type": "string",
          "pattern": "^[a-z][A-Za-z0-9]{0,31}$"
        },
        "code": {
          "type": "string",
          "maxLength": 128,
          "pattern": "^[a-z][A-Za-z0-9]*\\.[a-z][A-Za-z0-9]*$"
        },
        "parameters": {
          "type": "object",
          "maxProperties": 16,
          "propertyNames": {
            "pattern": "^[a-z][A-Za-z0-9]{0,31}$"
          },
          "additionalProperties": {
            "$ref": "#/$defs/errorParameter"
          }
        },
        "cause": {
          "$ref": "#/$defs/storedError"
        },
        "underlying": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "domain",
            "code"
          ],
          "properties": {
            "domain": {
              "type": "string",
              "minLength": 1,
              "maxLength": 128
            },
            "code": {
              "type": "integer"
            }
          }
        }
      }
    },
    "errorParameter": {
      "oneOf": [
        {
          "$ref": "#/$defs/textParameter"
        },
        {
          "$ref": "#/$defs/integerParameter"
        }
      ]
    },
    "textParameter": {
      "type": "object",
      "minProperties": 1,
      "maxProperties": 1,
      "propertyNames": {
        "enum": [
          "text",
          "fileName"
        ]
      },
      "additionalProperties": {
        "type": "object",
        "additionalProperties": false,
        "required": [
          "_0"
        ],
        "properties": {
          "_0": {
            "type": "string",
            "maxLength": 1024
          }
        }
      }
    },
    "integerParameter": {
      "type": "object",
      "minProperties": 1,
      "maxProperties": 1,
      "propertyNames": {
        "enum": [
          "bytes",
          "count",
          "durationMs"
        ]
      },
      "additionalProperties": {
        "type": "object",
        "additionalProperties": false,
        "required": [
          "_0"
        ],
        "properties": {
          "_0": {
            "type": "integer"
          }
        }
      }
    },
    "slotSummary": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "versionCode",
        "setDigest",
        "size",
        "fileCount"
      ],
      "properties": {
        "versionCode": {
          "$ref": "#/$defs/versionCode"
        },
        "versionName": {
          "$ref": "#/$defs/label"
        },
        "setDigest": {
          "$ref": "#/$defs/sha256Digest"
        },
        "size": {
          "type": "integer",
          "minimum": 1,
          "maximum": 8589934592
        },
        "fileCount": {
          "type": "integer",
          "minimum": 1,
          "maximum": 256
        }
      }
    },
    "stagedSlotSummary": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "versionCode",
        "setDigest",
        "size",
        "fileCount",
        "origin"
      ],
      "properties": {
        "versionCode": {
          "$ref": "#/$defs/versionCode"
        },
        "versionName": {
          "$ref": "#/$defs/label"
        },
        "setDigest": {
          "$ref": "#/$defs/sha256Digest"
        },
        "size": {
          "type": "integer",
          "minimum": 1,
          "maximum": 8589934592
        },
        "fileCount": {
          "type": "integer",
          "minimum": 1,
          "maximum": 256
        },
        "origin": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "type"
          ],
          "properties": {
            "type": {
              "enum": [
                "local",
                "direct",
                "fdroid",
                "github",
                "manualFile"
              ]
            },
            "url": {
              "$ref": "#/$defs/httpsURL"
            },
            "declaredDigests": {
              "type": "array",
              "minItems": 1,
              "maxItems": 256,
              "items": {
                "$ref": "#/$defs/sha256Digest"
              }
            }
          },
          "if": {
            "properties": {
              "type": {
                "enum": [
                  "local",
                  "manualFile"
                ]
              }
            }
          },
          "then": {
            "not": {
              "required": [
                "url"
              ]
            }
          }
        }
      }
    },
    "artifacts": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "currentMatchesAndroid"
      ],
      "properties": {
        "current": {
          "$ref": "#/$defs/slotSummary"
        },
        "previous": {
          "$ref": "#/$defs/slotSummary"
        },
        "staged": {
          "$ref": "#/$defs/stagedSlotSummary"
        },
        "currentMatchesAndroid": {
          "type": "boolean"
        }
      },
      "dependentRequired": {
        "previous": [
          "current"
        ],
        "staged": [
          "current"
        ]
      },
      "if": {
        "not": {
          "required": [
            "current"
          ]
        }
      },
      "then": {
        "properties": {
          "currentMatchesAndroid": {
            "const": false
          }
        }
      }
    },
    "android": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "minSdk",
        "targetSdk",
        "nativeAbis",
        "userdataGeneration",
        "lastSyncedAt"
      ],
      "properties": {
        "updateOwner": {
          "$ref": "#/$defs/packageId"
        },
        "installerOfRecord": {
          "$ref": "#/$defs/packageId"
        },
        "firstInstallTime": {
          "$ref": "#/$defs/date"
        },
        "lastUpdateTime": {
          "$ref": "#/$defs/date"
        },
        "minSdk": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10000
        },
        "targetSdk": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10000
        },
        "nativeAbis": {
          "type": "array",
          "maxItems": 8,
          "uniqueItems": true,
          "items": {
            "type": "string",
            "pattern": "^[a-z0-9_-]{1,32}$"
          }
        },
        "userdataGeneration": {
          "$ref": "#/$defs/uuid"
        },
        "lastSyncedAt": {
          "$ref": "#/$defs/date"
        }
      }
    },
    "source": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "at"
      ],
      "properties": {
        "kind": {
          "enum": [
            "file",
            "provider",
            "wrapperBootstrap",
            "adopted"
          ]
        },
        "at": {
          "$ref": "#/$defs/date"
        },
        "origin": {
          "enum": [
            "addFlow",
            "document",
            "dropOnHome",
            "cli",
            "wrap"
          ]
        },
        "fileNames": {
          "type": "array",
          "minItems": 1,
          "maxItems": 20,
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 255,
            "pattern": "^[^/]+$"
          }
        },
        "container": {
          "enum": [
            "apk",
            "apks",
            "xapk",
            "apkm",
            "zip"
          ]
        },
        "providerType": {
          "$ref": "#/$defs/providerType"
        },
        "wrapperBundleId": {
          "type": "string",
          "maxLength": 255,
          "pattern": "^io\\.apkrun\\.android\\.[A-Za-z0-9.-]+$"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "kind": {
                "const": "file"
              }
            }
          },
          "else": {
            "not": {
              "anyOf": [
                {
                  "required": [
                    "origin"
                  ]
                },
                {
                  "required": [
                    "fileNames"
                  ]
                }
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "enum": [
                  "file",
                  "provider"
                ]
              }
            }
          },
          "else": {
            "not": {
              "required": [
                "container"
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "provider"
              }
            }
          },
          "then": {
            "required": [
              "providerType"
            ]
          },
          "else": {
            "not": {
              "required": [
                "providerType"
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "const": "wrapperBootstrap"
              }
            }
          },
          "then": {
            "required": [
              "wrapperBundleId"
            ]
          },
          "else": {
            "not": {
              "required": [
                "wrapperBundleId"
              ]
            }
          }
        }
      ]
    },
    "operationSummary": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "operationID",
        "startedAt",
        "finishedAt",
        "result"
      ],
      "properties": {
        "kind": {
          "enum": [
            "firstInstall",
            "reinstall",
            "update",
            "rollback",
            "uninstall",
            "adopt"
          ]
        },
        "operationID": {
          "$ref": "#/$defs/uuid"
        },
        "startedAt": {
          "$ref": "#/$defs/date"
        },
        "finishedAt": {
          "$ref": "#/$defs/date"
        },
        "fromVersionCode": {
          "$ref": "#/$defs/versionCode"
        },
        "toVersionCode": {
          "$ref": "#/$defs/versionCode"
        },
        "result": {
          "enum": [
            "succeeded",
            "failed",
            "interrupted",
            "rollbackUnavailable"
          ]
        },
        "healthPending": {
          "const": true
        },
        "healthResult": {
          "enum": [
            "passed",
            "failed"
          ]
        },
        "failureCount": {
          "type": "integer",
          "minimum": 1,
          "maximum": 1000
        },
        "error": {
          "$ref": "#/$defs/storedError"
        }
      },
      "allOf": [
        {
          "if": {
            "properties": {
              "result": {
                "const": "failed"
              }
            }
          },
          "then": {
            "required": [
              "failureCount"
            ]
          },
          "else": {
            "not": {
              "required": [
                "failureCount"
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "result": {
                "enum": [
                  "succeeded",
                  "interrupted"
                ]
              }
            }
          },
          "then": {
            "not": {
              "required": [
                "error"
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "result": {
                "const": "rollbackUnavailable"
              }
            }
          },
          "then": {
            "properties": {
              "kind": {
                "const": "rollback"
              }
            }
          }
        },
        {
          "if": {
            "anyOf": [
              {
                "required": [
                  "healthPending"
                ]
              },
              {
                "required": [
                  "healthResult"
                ]
              }
            ]
          },
          "then": {
            "properties": {
              "kind": {
                "const": "update"
              },
              "result": {
                "const": "succeeded"
              }
            },
            "not": {
              "required": [
                "healthPending",
                "healthResult"
              ]
            }
          }
        },
        {
          "if": {
            "properties": {
              "kind": {
                "enum": [
                  "firstInstall",
                  "uninstall",
                  "adopt"
                ]
              }
            }
          },
          "then": {
            "not": {
              "required": [
                "fromVersionCode"
              ]
            }
          }
        }
      ]
    }
  }
}
```

---

## 3. Package settings (`settings.json`)

### 3.1 Keys and defaults

This table is the authority for the package settings keys and defaults. The UI and CLI columns and the design links are in [configuration.md](configuration.md) §3.1. Every key is optional in the file. An absent key has the default.

| Key | Type | Required | Constraints | Default | Applies | Meaning |
|---|---|---|---|---|---|---|
| `window.mode` | enum | no | `secondaryDisplay`, `primaryDisplayCompatibility` | `secondaryDisplay` | next session | the display mode ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §8) |
| `window.defaultWidth` | integer (pt) | no | 320–8192 | `480`, or `850` when the launcher activity requests landscape | next session | the width of a new window without a saved frame |
| `window.defaultHeight` | integer (pt) | no | 400–8192 | `850`, or `480` in landscape | next session | the height of such a window |
| `window.resizable` | boolean | no | | `true` (`false` with fallback B) | live | whether the window can be resized |
| `window.alwaysOnTop` | boolean | no | | `false` | live | floating window level |
| `window.zoom` | number | no | 0.75–2.0 | `1.0` | live (next session with fallback B) | Android UI scale ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §6.1) |
| `window.closeBehavior` | enum | no | `stop`, `keepRunning` | `stop` | live, read when the window closes | what closing the window does |
| `input.escapeKey` | enum | no | `back`, `escape` | `back` | next session | what Esc sends |
| `input.secondaryClick` | enum | no | `mouseSecondary`, `longPress` | `mouseSecondary` | next session | what a right click sends |
| `input.scrollMode` | enum | no | `scroll`, `touchDrag` | `scroll` | next session | how scrolling is sent |
| `input.hover` | boolean | no | | `true` | next session | send mouse hover events |
| `input.sendCommandKey` | boolean | no | | `false` | next session | send ⌘ to the app |
| `integrations.clipboard` | boolean | no | | `true` | live | clipboard sync |
| `integrations.notifications` | boolean | no | | `true` | live | notification forwarding |
| `integrations.links` | enum | no | `ask`, `mac`, `android` | `ask` | live | where links open |
| `integrations.files` | boolean | no | | `true` | live | file open and share |
| `integrations.sharedFolders` | enum | no | `off`, `readOnly`, `readWrite` | `off` | live | shared folder access |
| `integrations.microphone` | boolean | no | | `false` | live. Turning it on for the first package, or off for the last, needs a runtime restart | microphone input |
| `update.mode` | enum | no | `automatic`, `notifyOnly` | `automatic` | next check | the update mode. It has an effect only while `updateAuthority` is `apkrun` ([../02-design/update-system.md](../02-design/update-system.md) §2.2) |
| `update.autoRollback` | boolean | no | | `true` | next health-check result | roll back an update that fails its health check |
| `update.healthCheckLaunch` | boolean | no | | `true` | next update | launch the app briefly after an update. `false` limits the check to `versionOnly` |

- The window size is clamped when it is used: to 90 % of the screen's visible frame and to the 4095 px backing limit ([../02-design/display-and-windowing.md](../02-design/display-and-windowing.md) §6.2). A frame saved by AppKit wins over the default size.
- The landscape defaults depend on the launcher activity. The resolver decides them. They are never written.
- The integration defaults for a new package come from `integrations.defaults.*` ([configuration.md](configuration.md) §2.8), not from this table (§3.5).

### 3.2 Storage form

- Dotted keys are nested objects: `window.zoom` is `{"window": {"zoom": 1.25}}`.
- The file holds only explicit values: the user's values and the values copied at the first record ([configuration.md](configuration.md) §1.2). The resolver needs this to tell a user value from a recommendation.
- A group object without keys is omitted. `{"schemaVersion": 1}` is a valid file.
- `schemaVersion` is required. The top-level groups are `window`, `input`, `integrations`, and `update`.
- Numbers: sizes are integers. `zoom` is a JSON number. The writer stores the value as given, after validation.

### 3.3 Example

```json
{
  "integrations": {
    "links": "mac",
    "notifications": false
  },
  "schemaVersion": 1,
  "update": {
    "mode": "notifyOnly"
  },
  "window": {
    "alwaysOnTop": true,
    "defaultHeight": 900,
    "defaultWidth": 520,
    "zoom": 1.25
  }
}
```

### 3.4 JSON Schema

This schema is the writer's contract. It rejects unknown keys. Readers are more lenient and validate key by key (§4.2).

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:package-settings:1",
  "title": "APKRun package settings (Packages/<dir>/settings.json), schemaVersion 1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schemaVersion"
  ],
  "properties": {
    "schemaVersion": {
      "const": 1
    },
    "window": {
      "type": "object",
      "additionalProperties": false,
      "minProperties": 1,
      "properties": {
        "mode": {
          "enum": [
            "secondaryDisplay",
            "primaryDisplayCompatibility"
          ]
        },
        "defaultWidth": {
          "type": "integer",
          "minimum": 320,
          "maximum": 8192
        },
        "defaultHeight": {
          "type": "integer",
          "minimum": 400,
          "maximum": 8192
        },
        "resizable": {
          "type": "boolean"
        },
        "alwaysOnTop": {
          "type": "boolean"
        },
        "zoom": {
          "type": "number",
          "minimum": 0.75,
          "maximum": 2.0
        },
        "closeBehavior": {
          "enum": [
            "stop",
            "keepRunning"
          ]
        }
      }
    },
    "input": {
      "type": "object",
      "additionalProperties": false,
      "minProperties": 1,
      "properties": {
        "escapeKey": {
          "enum": [
            "back",
            "escape"
          ]
        },
        "secondaryClick": {
          "enum": [
            "mouseSecondary",
            "longPress"
          ]
        },
        "scrollMode": {
          "enum": [
            "scroll",
            "touchDrag"
          ]
        },
        "hover": {
          "type": "boolean"
        },
        "sendCommandKey": {
          "type": "boolean"
        }
      }
    },
    "integrations": {
      "type": "object",
      "additionalProperties": false,
      "minProperties": 1,
      "properties": {
        "clipboard": {
          "type": "boolean"
        },
        "notifications": {
          "type": "boolean"
        },
        "links": {
          "enum": [
            "ask",
            "mac",
            "android"
          ]
        },
        "files": {
          "type": "boolean"
        },
        "sharedFolders": {
          "enum": [
            "off",
            "readOnly",
            "readWrite"
          ]
        },
        "microphone": {
          "type": "boolean"
        }
      }
    },
    "update": {
      "type": "object",
      "additionalProperties": false,
      "minProperties": 1,
      "properties": {
        "mode": {
          "enum": [
            "automatic",
            "notifyOnly"
          ]
        },
        "autoRollback": {
          "type": "boolean"
        },
        "healthCheckLaunch": {
          "type": "boolean"
        }
      }
    }
  }
}
```

### 3.5 Resolution and the first record

These rules are defined in [configuration.md](configuration.md). They are only summarized here.

- **Effective value** ([configuration.md](configuration.md) §3.2): the global switch `integrations.enabled.<name> = false`, then the value in this file, then the compatibility database recommendation (#090), then the default of §3.1. Recommendations are never written to this file.
- **First record** ([configuration.md](configuration.md) §3.3, §4): at install and import, at a bootstrap import, and at the approval of a wrapper whose package has no settings. The sources are the command's flags, then `wrapper.json` ([wrapper-json.md](wrapper-json.md)), then `integrations.defaults.*`. A value equal to the default of §3.1 is not written. Authority and provider go to the record (§2.4), not to this file.
- **Unmanaged packages** have no file. They use the defaults, with `integrations.notifications` off ([configuration.md](configuration.md) §3.2).

### 3.6 Changes

- `updatePackageSettings(id, patch)` applies a JSON merge patch (RFC 7396) to the nested form of §3.2 ([configuration.md](configuration.md) §1.4). `null` removes a key (**Reset**). The whole patch is validated first. One bad key rejects the whole patch, and nothing is written.
- Setting a key explicitly to its default stores it, because an explicit value beats a recommendation. This differs from the first record on purpose.
- A patch that changes nothing writes nothing and posts no event.
- After a write the store posts `PackageChange.settingsChanged(id, keys)` with dotted keys. A change of `window.resizable`, `window.alwaysOnTop`, or `window.zoom` also sends `windowPrefsChanged` to the package's wrapper ([configuration.md](configuration.md) §1.5).
- CLI: `apkrun settings <package> list [--json] | get <key> | set <key> <value> | reset (<key> | --all)` ([../02-design/cli.md](../02-design/cli.md) §4.2). `reset --all` writes `{"schemaVersion": 1}`.
- `setUpdatePolicy` writes `update.mode` and the record's authority and provider together ([../02-design/update-system.md](../02-design/update-system.md) §2.3). It writes `settings.json` first, then `metadata.json` (§6.2).

---

## 4. Validation rules

### 4.1 On write

| Check | Failure |
|---|---|
| A settings patch names an unknown key | `store.unknownSetting(key)`, CLI exit 4 |
| A settings value has the wrong type or is outside §3.1 | `store.invalidSettingValue(key, allowed)`, CLI exit 64 |
| A provider spec does not parse or breaks §2.4 | `setUpdatePolicy` fails with `update.providerNotConfigured`, variant `invalidSpec` ([error-catalog.md](error-catalog.md) §11). Nothing is written |
| A provider test request fails (F-Droid, GitHub) | `update.providerUnreachable` or `update.providerMetadataInvalid` |
| The record fails §2.6 or §2.5 before a write | a programming error. The write is refused, the transaction aborts, and the error is `runtime.internal` with a fault log |
| The package or the store is read-only (§4.2, §5.3) | `store.storeReadOnly(reason)` for the record. `runtime.hostStartupFailed(step:)` when APKStoreCore is degraded |

Every write is atomic: a temporary file in the same directory, `fcntl(F_BARRIERFSYNC)`, then a rename over the old file ([../02-design/package-store.md](../02-design/package-store.md) §5.1).

### 4.2 On load

| Problem | `metadata.json` | `settings.json` |
|---|---|---|
| Older `schemaVersion` | migrated (§5.2) | migrated (§5.2) |
| Newer `schemaVersion` | that package is read-only with `store.metadataUnreadable`. The file is never written ([../02-design/package-store.md](../02-design/package-store.md) §5.4) | the same as for `metadata.json`: that package is read-only with `store.metadataUnreadable` ([configuration.md](configuration.md) §8.3). The file is never written |
| Not JSON, larger than §1.2, or no `schemaVersion` | that package is read-only with `store.metadataUnreadable` and a health error. The file is kept as it is | renamed to `settings.json.corrupt-<time>`. Every key uses its default. The next change writes a new file ([configuration.md](configuration.md) §8.2) |
| A required field is missing, or a field breaks §2.6 or §2.5 | the same as the row above | — |
| Unknown field or key | ignored. It is dropped at the next write | ignored, with one warning per load. It is dropped at the next write |
| Invalid value of a known key | the record is unreadable (row 3). Exception: an invalid provider configuration (§2.4) | that key uses its default. An error is logged. The value is dropped at the next write |
| File missing | the journal decides (§6.3) | read as `{"schemaVersion": 1}` |

- A problem in one package's files affects no other package.
- A read-only package is listed with its last readable facts where possible. It cannot be updated, rolled back, or uninstalled until the problem is fixed. **Remove from APKRun** (`forget`) still works.
- `<time>` in `.corrupt-<time>` is the UTC time in the form `20261002T091203Z`.

---

## 5. Versioning and migration

### 5.1 Rules

- `schemaVersion` is an integer. This build's values are in `components.json` `dataSchemas` (`packageRecord` 1, `packageSettings` 1, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1).
- Every change raises the version, also an additive one. `Codable` drops unknown keys, so an older build that wrote the file would lose the new field ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- A migration never changes what a value means. Renaming or removing a field is a migration step.
- A build migrates every older version in the window of R5 (24 months, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.3).
- The schema `$id` carries the version: `urn:apkrun:schema:package-record:<n>` and `urn:apkrun:schema:package-settings:<n>`.

### 5.2 Migrating older files

At `open` ([../02-design/package-store.md](../02-design/package-store.md) §5.4 step 2), before recovery:

1. The store begins one journal transaction of kind `schemaMigration` for all packages that have an older file ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
2. For each file: keep the original bytes as `metadata.v<old>.json` or `settings.v<old>.json` in the same directory. Migrate in memory, validate against the current schema, and replace the file with `FileManager.replaceItemAt`. Journal step `migrated` with the package ID.
3. Commit. Backups are deleted 90 days after the migration.

- Recovery of an unfinished `schemaMigration` continues with the files that still have the old version. A file at the current version is skipped.
- A failure makes APKStoreCore start degraded with `maintenance.schemaMigrationFailed(file, from, to, detail)`. The original file and its backup stay unchanged.
- Golden fixtures prove each step (§9).

### 5.3 Newer files

A newer file appears only after APKRun was downgraded. §4.2 lists the behavior. The store never writes, migrates, or resets a file with a newer version.

---

## 6. Journal interplay

### 6.1 Transactions

The transaction kinds are in [../02-design/package-store.md](../02-design/package-store.md) §5.2. Both files are written before the step `metadataWritten` is journaled.

| Kind | `metadata.json` | `settings.json` |
|---|---|---|
| `firstInstall` | created with state `installed`, `current`, the Android facts, and `lastOperation` | created with the first-record values (§3.5) |
| `reinstall` | `versionCode`, Android facts, `state` `installed`, `lastOperation` `reinstall`. `current` is replaced for `reinstallSameVersion` | unchanged |
| `stage` | `artifacts.staged` set or replaced | unchanged |
| `update` | slots rotated (`previous` ← `current` ← `staged`), `versionCode`, `lastOperation` `update` with `healthPending` | unchanged |
| `rollback` | `current` ← `previous`, `previous` removed, `lastOperation` `rollback` | unchanged |
| `uninstall` with keep data | `state` `uninstalledKeepingData`, slots removed, `lastOperation` `uninstall` | kept |
| `uninstall` without keep data | step `recordRemoved`: the directory goes to `.trash/` | removed with the directory |
| `forget` | step `recordRemoved` | removed with the directory |
| `discardStaged` | `artifacts.staged` removed | unchanged |
| `schemaMigration` | §5.2 | §5.2 |

Recovery writes the record again from the transaction's `begin` line (`from`, `to`, `setDigest`) and the slots' `artifact.json`. That write is idempotent. A crash never leaves a partly written file, because of the atomic rename.

### 6.2 Writes outside transactions

These writes change only the files and never a slot or Android. They take the package's operation lock ([../02-design/package-store.md](../02-design/package-store.md) §5.3) and use the atomic write of §4.1. They are not journaled.

| Write | Fields |
|---|---|
| Reconciliation ([../02-design/package-store.md](../02-design/package-store.md) §9.2) | `displayName`, `versionName`, `versionCode` (Android has a higher version), `signingCertificates`, `signingLineage`, `android.*`, `currentMatchesAndroid`, `state` (`needsReinstall`, `broken`) |
| `recordHealth(id, result)` | `lastOperation.healthPending` removed, `healthResult` set |
| A failed operation that did not reach Android | `lastOperation` with `result` `failed` and `failureCount` |
| Adopt ([../02-design/package-store.md](../02-design/package-store.md) §9.3) | a new record with `lastOperation` `adopt`, and a new `settings.json` |
| `setUpdatePolicy` | `settings.json` `update.mode` first, then `updateAuthority` and `updateProvider` in `metadata.json` |
| `updatePackageSettings` | `settings.json` only |

The order for `setUpdatePolicy` is chosen so that a crash between the two writes never turns on automatic updates by itself: the mode alone has no effect without the authority `apkrun`.

### 6.3 A missing `metadata.json`

- An unfinished `firstInstall` for the directory: recovery decides ([../02-design/package-store.md](../02-design/package-store.md) §5.5).
- No transaction refers to the directory: the directory is moved to `.trash/` with a health warning ([../02-design/package-store.md](../02-design/package-store.md) §3.2).
- A `metadata.json` that exists but cannot be read is never moved. §4.2 applies.

---

## 7. Writers and readers

| Role | Component | Notes |
|---|---|---|
| Writer | `PackageStore` in APKStoreCore (apkrund, or the embedded runtime of `apkrun dev`) | the only writer of both files ([configuration.md](configuration.md) §1.1) |
| Reader | `PackageStore.open` | builds the directory index, migrates, recovers (§5, §6) |
| Reader | RuntimeHost for RuntimeAPI | `packageInfo` returns the record as `WirePackageRecord` and the settings as `ResolvedPackageSettings` ([runtime-api.md](runtime-api.md) §8.3) |
| Reader | UpdateCore | authority, provider, and `update.*` through `PackageStore` |
| Reader | sessions, IntegrationCore, DisplayPool | settings through `PackageStore.settings(for:)`. They do not cache across `settingsChanged` ([../02-design/package-store.md](../02-design/package-store.md) §2.4) |
| Reader | WrapperCore | `displayName` and the settings that seed `wrapper.json` ([../02-design/wrapper.md](../02-design/wrapper.md) §6.1, [wrapper-json.md](wrapper-json.md)) |
| Reader | DiagnosticsCore | an allowlisted copy (§8) |
| Reader (tests) | the fixtures of §9 | |

No other process reads these files. APKRun.app, the CLI, and wrappers use RuntimeAPI. Hand edits are not supported. apkrund reads them only at its next start.

---

## 8. Diagnostics and privacy

- A diagnostics bundle includes each record with the allowlist of [../02-design/diagnostics.md](../02-design/diagnostics.md) §6.2: package ID, label, version name and code, state, installer, update authority and owner, provider type and host, signer digests truncated to 12 hex characters, and sizes.
- Left out of the bundle: `source.fileNames`, `artifacts.staged.origin.url` except its host, and every provider configuration value except the type and the host (§2.4). The Local `bookmark` is never copied.
- Each `settings.json` is copied as is. Every key of §3.1 is on the allowlist ([configuration.md](configuration.md) §1.7).
- Logs name the package ID and the provider type and host. They never contain paths from the user's disk at `info` level or above.

---

## 9. Tests and fixtures

Fixtures:

- `Tests/Fixtures/schemas/packageRecord/v1.json` and `v1.expected.json` (identical for v1), `Tests/Fixtures/schemas/packageSettings/v1.json` and `v1.expected.json` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5). Each later version adds `v<n>.json` and its expected result.
- `Tests/Fixtures/schemas/packageRecord/valid/*.json` and `invalid/*.json`, and the same for `packageSettings`. The valid set contains the examples of §2.1 and §3.3. Each invalid fixture breaks one rule, and its file name names the rule (`r2-apkrun-without-provider.json`).

| Tier | Test | Task |
|---|---|---|
| T0 | Schema: every valid fixture passes §2.6 or §3.4, and every invalid fixture fails | #027, #037 |
| T0 | Model and schema agree: every valid fixture decodes with `Codable`, encodes to the same bytes, and passes `PackageRecordValidator`. Every invalid fixture fails with the expected rule of §2.5 | #027, #037 |
| T0 | `PackageState` encoding: every row of §2.3.1, both directions. `{"installed": {}}` is refused | #027 |
| T0 | Provider configuration: spec parsing and normalization for the four types (§2.4), refusal of `http` in release builds, F-Droid fingerprint normalization, GitHub name rules | #037, #050, #051, #052 |
| T0 | Migration: `v<n>.json` → current equals `v<n>.expected.json`. A newer `schemaVersion` gives the behavior of §4.2 | #027, #057 |
| T0 | Settings: merge patch with `null`, unknown key (`store.unknownSetting`), invalid value (`store.invalidSettingValue`), no-op patch without event, explicit default stored | #079 |
| T0 | Settings load rules of §4.2: unknown key dropped at the next write, invalid value → default, corrupt file renamed | #079 |
| T0 | Resolver precedence and first-record rules ([configuration.md](configuration.md) §3.2, §3.3) | #079, #090 |
| T1 | Crash injection at every step of every kind (§6.1): after restart both files parse, and the record matches the slots | #027, #038 |
| T1 | `setUpdatePolicy` with a crash between the two writes (§6.2) | #037 |
| T1 | APKRun update: the decoded records are equal field by field before and after ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5) | #057 |
