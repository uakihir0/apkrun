# Wrapper Files (`wrapper.json`, `bootstrap.json`, `registry.json`)

This document defines three JSON files of Mac app wrappers. `wrapper.json` sits in every wrapper bundle. `bootstrap.json` sits in portable and distribution wrappers and describes the APK set they carry. `registry.json` lives in APKRun's data directory and is the only record of which wrapper may open which package.

The inline JSON Schemas (draft 2020-12, §2.7, §3.5, §4.5) define the **structure**. This document defines the **semantics**: the checks across files and Info.plist, the mapping into the package store, and the behavior on errors. [wrapper.md](../02-design/wrapper.md) is authoritative for the wrapper design.

---

## 1. Overview

### 1.1 Files

| File | Location | Swift type | Version field | Writer | Readers |
|---|---|---|---|---|---|
| `wrapper.json` | `‹Wrapper›.app/Contents/Resources/wrapper.json` | `WrapperManifest` | `formatVersion` 1 | `AppWrapperGenerator`, once | the launcher, `WrapperApprovalService`, `WrapperValidator`, the store at the first record |
| `bootstrap.json` | `‹Wrapper›.app/Contents/Resources/bootstrap/bootstrap.json` | `BootstrapManifest` | `formatVersion` 1 | `AppWrapperGenerator`, for `portable` and `distribution` | the launcher, `importBootstrap` in RuntimeHost |
| `registry.json` | `Wrappers/registry.json` in the data directory ([filesystem-layout.md](../01-architecture/filesystem-layout.md)) | `WrapperRegistryFile` | `schemaVersion` 1 (`dataSchemas.wrapperRegistry`) | `WrapperRegistry` in apkrund, only | `WrapperRegistry`, DiagnosticsCore |

- The bundle files are sealed by the code signature. APKRun never changes them after signing (FR-WRP-04). A change of name, icon, or launcher regenerates the whole `Contents` ([wrapper.md](../02-design/wrapper.md) §9.3).
- The bundle ID and file name are derived, not stored ([wrapper.md](../02-design/wrapper.md) §4.1, §4.3).
- The bundle files are not trusted for authorization. apkrund decides from `registry.json` alone ([wrapper.md](../02-design/wrapper.md) §7.2).

### 1.2 Encoding

- Each file is one UTF-8 JSON object, written by `JSONEncoder` with `.sortedKeys`, `.prettyPrinted`, and `.withoutEscapingSlashes`, plus a trailing newline. The same inputs give the same bytes ([wrapper.md](../02-design/wrapper.md) §3, §6.5).
- `null` is written only where a field is **nullable**. Elsewhere an absent optional value is omitted.
- Enums are strings. Dates are ISO 8601 UTC, written with milliseconds and `Z`. Readers also accept a date without fractional seconds.
- Size limits: `wrapper.json` and `bootstrap.json` at most 64 KiB, `registry.json` at most 4 MiB. A larger file is unreadable.

### 1.3 Common value types

`PackageID`, `VersionCode`, `SHA256Digest`, `Date`, and `UpdateProviderRef` are defined in [package-metadata-json.md](package-metadata-json.md) §1.3 and §2.4.

| Type | JSON | Rule |
|---|---|---|
| `BundleID` | string | `io.apkrun.android.` + the mapped package ID. Characters `A–Z a–z 0–9 - .`. At most 255 characters. Compared ignoring case ([wrapper.md](../02-design/wrapper.md) §4.1) |
| `CDHash` | string | 40 lowercase hex characters (`kSecCodeInfoUnique`) ([wrapper.md](../02-design/wrapper.md) §7.1) |
| `AppVersion` | string | `MAJOR.MINOR.PATCH`, no leading zeros, compared numerically. A two-part value is read as `x.y.0` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1) |
| `APIVersion` | string | `MAJOR.MINOR`, no leading zeros ([runtime-api.md](runtime-api.md) §2.1) |
| `Bookmark` | string | Base64 of bookmark data, at most 8 KiB after decoding ([wrapper.md](../02-design/wrapper.md) §6.2) |

### 1.4 Wrapper kinds and their files

| `kind` | `bootstrap/` | Signature | Registry entry on the creating Mac | Registry entry on another Mac |
|---|---|---|---|---|
| `local` | no | ad hoc | yes, `approval: generated` | after approval, `approval: user`. Opening it needs the package installed there |
| `portable` | yes | ad hoc | yes, `approval: generated` | after approval, `approval: user`. It can install the package from `bootstrap/` |
| `distribution` | yes | Developer ID, optionally notarized | none. Built in staging and written to the output directory | after approval, `approval: user`. Same as `portable` |

`wrapper.json` has the same format for all kinds. Only `kind` differs, and `updates` never carries a `local` provider (§2.5).

---

## 2. `wrapper.json`

### 2.1 Examples

A portable wrapper for the package of [package-metadata-json.md](package-metadata-json.md) §2.1:

```json
{
  "application": {
    "displayName": "Notes",
    "packageId": "org.example.notes"
  },
  "formatVersion": 1,
  "integration": {
    "links": "mac",
    "notifications": false
  },
  "kind": "portable",
  "runtime": {
    "launcherAPI": "1.0",
    "minimumVersion": "1.0.0"
  },
  "updates": {
    "authority": "apkrun",
    "mode": "notifyOnly",
    "provider": {
      "configuration": { "url": "https://downloads.example.org/notes/manifest.json" },
      "type": "direct"
    }
  },
  "window": {
    "defaultHeight": 900,
    "defaultWidth": 520,
    "mode": "standard",
    "resizable": true
  }
}
```

A local wrapper for an adopted package. It has no `updates` object, because the package's authority is `external`:

```json
{
  "application": {
    "displayName": "Chat",
    "packageId": "com.example.chat"
  },
  "formatVersion": 1,
  "integration": {},
  "kind": "local",
  "runtime": {
    "launcherAPI": "1.0",
    "minimumVersion": "1.0.0"
  },
  "window": {
    "defaultHeight": 850,
    "defaultWidth": 480,
    "mode": "standard",
    "resizable": true
  }
}
```

### 2.2 Fields

A reader refuses the file when an identity field is wrong (§5.1).

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `formatVersion` | integer | yes | `1` | the wrapper format. Equals Info.plist `APKRunWrapperFormat` (§2.3) |
| `kind` | enum | yes | `local`, `portable`, `distribution` | the wrapper kind ([wrapper.md](../02-design/wrapper.md) §6.1, §10, §11). Equals `APKRunWrapperKind` |
| `application.packageId` | `PackageID` | yes | | the Android package. Equals `APKRunPackageID` |
| `application.displayName` | string | yes | 1–1024 characters | the name shown before the launcher connects. Equals `CFBundleDisplayName`, after [wrapper.md](../02-design/wrapper.md) §4.3 step 1 |
| `runtime.minimumVersion` | `AppVersion` | yes | | the lowest APKRun version this launcher works with: `LauncherBuild.minimumRuntimeVersion`, not the version that generated the wrapper |
| `runtime.launcherAPI` | `APIVersion` | yes | | the RuntimeAPI version the launcher was built against. Equals `APKRunLauncherAPI` |

Preference fields are initial values for the package store (§2.4). A reader validates each key alone and ignores a bad one.

| Field | Type | Constraints | Meaning |
|---|---|---|---|
| `window.mode` | enum | `standard`, `compatibility` | `standard` becomes `window.mode = secondaryDisplay`; `compatibility` becomes `primaryDisplayCompatibility` |
| `window.defaultWidth` | integer (pt) | 320–8192 | the default window width |
| `window.defaultHeight` | integer (pt) | 400–8192 | the default window height |
| `window.resizable` | boolean | | whether the window can be resized |
| `updates.authority` | enum | `apkrun`, `manual` | the initial update authority |
| `updates.mode` | enum | `automatic`, `notifyOnly` | the initial `update.mode` |
| `updates.provider` | `UpdateProviderRef` or `null` | not `type` `local`. No credentials | the initial provider ([package-metadata-json.md](package-metadata-json.md) §2.4) |
| `integration.clipboard` | boolean | | initial `integrations.clipboard` |
| `integration.notifications` | boolean | | initial `integrations.notifications` |
| `integration.links` | enum | `ask`, `mac`, `android` | initial `integrations.links` |
| `integration.files` | boolean | | initial `integrations.files` |
| `integration.sharedFolders` | enum | `off`, `readOnly`, `readWrite` | initial `integrations.sharedFolders` |
| `integration.microphone` | boolean | | initial `integrations.microphone` |

- The generator always writes `window` (all four keys), `integration` (possibly empty), and `updates` for `apkrun` and `manual` packages (§2.5). Readers accept each of them absent.
- Nothing is version-specific: no `versionCode`, `versionName`, APK path, or digest ([wrapper.md](../02-design/wrapper.md) §3).
- Unknown fields are ignored at every level. The generator never writes them.

### 2.3 Cross-checks with Info.plist and the bundle

The Info.plist keys are defined in [wrapper.md](../02-design/wrapper.md) §2.1.

| # | Check | Where | Failure |
|---|---|---|---|
| X1 | `application.packageId` equals `APKRunPackageID` | launcher startup step 1; approval ([wrapper.md](../02-design/wrapper.md) §7.3 step 1) | launcher: screen D, `wrapper.wrapperDamaged`. Approval: `wrapper.bundleInvalid(.packageMismatch)` |
| X2 | `formatVersion` equals `APKRunWrapperFormat`, and the reader supports it | launcher; approval | launcher: screen D. Approval: `wrapper.bundleInvalid(.wrapperJSONInvalid)` |
| X3 | `kind` equals `APKRunWrapperKind` | approval, `verifyWrapper` | `wrapper.bundleInvalid(.wrapperJSONInvalid)` |
| X4 | `runtime.launcherAPI` equals `APKRunLauncherAPI` | approval, `verifyWrapper` | `wrapper.bundleInvalid(.wrapperJSONInvalid)` |
| X5 | `CFBundleIdentifier` equals `map(APKRunPackageID)` ([wrapper.md](../02-design/wrapper.md) §4.1) | approval, `verifyWrapper` | `wrapper.bundleInvalid(.bundleIDMismatch)` |
| X6 | the signature is valid and its identifier equals `CFBundleIdentifier` | approval, `verifyWrapper` | `wrapper.bundleInvalid(.signatureInvalid)` or `(.identifierMismatch)` |

- The launcher checks only X1, X2, and §2.7. It uses its compiled `RuntimeAPI.version`, not `runtime.launcherAPI`, and does no signature check on the launch path ([wrapper.md](../02-design/wrapper.md) §5.2).
- The file name of the bundle is never checked. Users may rename a wrapper ([wrapper.md](../02-design/wrapper.md) §4.3).

### 2.4 Mapping into the package store

[configuration.md](configuration.md) §4 lists where each value goes, and §3.3 gives the order of sources. The store reads `wrapper.json` for this only at a bootstrap import (§3.4) and at the approval of a wrapper whose package has a record but no `settings.json`.

| `wrapper.json` | Target | Rule |
|---|---|---|
| `window.*` | `settings.json` `window.*` | mode mapped as in §2.2 |
| `updates.mode` | `settings.json` `update.mode` | |
| `updates.authority` `apkrun`, valid provider | record `updateAuthority` `apkrun`, `updateProvider` | the provider is validated as in [package-metadata-json.md](package-metadata-json.md) §2.4, without the test request, so an offline install works |
| `updates.authority` `apkrun`, `provider` `null`, absent, or invalid | record `updateAuthority` `manual`, no provider | a provider is required for `apkrun` ([package-metadata-json.md](package-metadata-json.md) §2.5 R2). Logged |
| `updates.authority` `manual` | record `updateAuthority` `manual`, and the valid provider | the provider is kept unused, as for **Manual** ([update-system.md](../02-design/update-system.md) §2.3) |
| no `updates` | record `updateAuthority` `manual`, default `update.mode` | the file-import default ([update-system.md](../02-design/update-system.md) §2.4) |
| `integration.<key>` | `settings.json` `integrations.<key>` | an absent key takes `integrations.defaults.<key>` of this Mac |

- A value that breaks §2.2 is treated as absent and logged. The other keys are still used ([configuration.md](configuration.md) §4).
- A value equal to the default of [package-metadata-json.md](package-metadata-json.md) §3.1 is not written ([configuration.md](configuration.md) §3.3). CLI flags of the installing command win over the file.
- A GitHub provider arrives without a token. Requests are anonymous until the user adds one on this Mac.
- After the first record, the store never reads `wrapper.json` for settings ([wrapper.md](../02-design/wrapper.md) §3).

### 2.5 How the generator fills the file

RuntimeHost builds the `WrapperConfiguration` from the store ([wrapper.md](../02-design/wrapper.md) §6.1).

| Field | Value |
|---|---|
| `application.displayName` | the display name written to `CFBundleDisplayName` |
| `runtime.minimumVersion` | `LauncherBuild.minimumRuntimeVersion` of the launcher template |
| `runtime.launcherAPI` | `RuntimeAPI.version` of the launcher template (`1.0` in v1) |
| `window.*` | all four keys: the package's explicit value from `settings.json`, else the built-in default (including the landscape default size). Compatibility recommendations are never written |
| `integration.*` | only the keys the package has explicitly in `settings.json` |
| `updates` | for `apkrun` and `manual` packages: the record's authority, the effective `update.mode`, and the provider. A `local` provider is written as `null`, and the authority as `manual`, because a local path and its bookmark are valid only on this Mac. Omitted for `googlePlay` and `external` |

### 2.6 Version fields and compatibility

| Field | Where else | v1 value | Used for |
|---|---|---|---|
| `formatVersion` | Info.plist `APKRunWrapperFormat`; registry `formatVersion` | `1` | the reader's format check (X2) |
| — | Info.plist `CFBundleShortVersionString`, `CFBundleVersion` | `1.0`, `1` | the Finder "Version" field ([wrapper.md](../02-design/wrapper.md) §2.1). A new `formatVersion` raises both |
| `runtime.launcherAPI` | Info.plist `APKRunLauncherAPI`; registry `launcherAPI` | `1.0` | apkrund's view of the launcher's API major: health `wrappers.launcher` and the update prompt ([wrapper.md](../02-design/wrapper.md) §9.4, §14) |
| — | Info.plist `APKRunLauncherVersion`; registry `launcherVersion` | the APKRun version that built the launcher | refresh reason `.launcher(version)` when it is below the current template ([wrapper.md](../02-design/wrapper.md) §9.1 step 6) |
| `runtime.minimumVersion` | — | `1.0.0` | compared with `HelloReply.runtimeVersion` by the launcher |

The launcher decides after `hello`: it compares `runtime.minimumVersion` with the runtime version, and its API version `M.m` with the served `N.n`. The result table (screens V and L, the N−1 rule) is [runtime-api.md](runtime-api.md) §2.4. The wrapper endpoint serves the majors in `RuntimeAPI.wrapperMajors` ([runtime-api.md](runtime-api.md) §2.1).

Rules for `formatVersion`:

- A wrapper is never migrated. A new format affects only newly generated wrappers.
- Additive optional fields do not raise `formatVersion`. Readers ignore unknown fields, and the file is never rewritten. Host data files differ ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- A change that an older reader would misread raises `formatVersion`: a new required field, a changed meaning, or a removed field.
- apkrund reads every `formatVersion` that a launcher of a served API major can have written.
- A launcher that writes format `n` sets `runtime.minimumVersion` to at least the first APKRun release that reads format `n`. An older APKRun shows screen V first. If it still sees an unknown format (`apkrun wrapper verify`, `approve`), the result is `wrapper.bundleInvalid(.wrapperJSONInvalid)`.

### 2.7 JSON Schema

The root schema is the reader's acceptance check (launcher startup step 1, approval). It checks identity fields strictly and preference sections only for their type. `$defs/generated` is the writer contract: every generated file must pass it, including the value rules of §2.2 and no unknown fields. The `updateProvider` reference points to [package-metadata-json.md](package-metadata-json.md) §2.6. Tests load both schemas into one registry.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:wrapper-json:1",
  "title": "APKRun wrapper.json, formatVersion 1 (reader acceptance; $defs/generated is the writer contract)",
  "type": "object",
  "required": ["formatVersion", "kind", "application", "runtime"],
  "properties": {
    "formatVersion": { "const": 1 },
    "kind": { "$ref": "#/$defs/kind" },
    "application": { "$ref": "#/$defs/application" },
    "runtime": { "$ref": "#/$defs/runtime" },
    "window": { "type": "object" },
    "updates": { "type": "object" },
    "integration": { "type": "object" }
  },
  "$defs": {
    "packageId": { "type": "string", "maxLength": 255, "pattern": "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$" },
    "kind": { "enum": ["local", "portable", "distribution"] },
    "appVersion": { "type": "string", "maxLength": 32, "pattern": "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" },
    "apiVersion": { "type": "string", "maxLength": 16, "pattern": "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" },
    "application": {
      "type": "object",
      "required": ["packageId", "displayName"],
      "properties": {
        "packageId": { "$ref": "#/$defs/packageId" },
        "displayName": { "type": "string", "minLength": 1, "maxLength": 1024 }
      }
    },
    "runtime": {
      "type": "object",
      "required": ["minimumVersion", "launcherAPI"],
      "properties": {
        "minimumVersion": { "$ref": "#/$defs/appVersion" },
        "launcherAPI": { "$ref": "#/$defs/apiVersion" }
      }
    },
    "window": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "mode": { "enum": ["standard", "compatibility"] },
        "defaultWidth": { "type": "integer", "minimum": 320, "maximum": 8192 },
        "defaultHeight": { "type": "integer", "minimum": 400, "maximum": 8192 },
        "resizable": { "type": "boolean" }
      }
    },
    "updates": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "authority": { "enum": ["apkrun", "manual"] },
        "mode": { "enum": ["automatic", "notifyOnly"] },
        "provider": {
          "oneOf": [
            { "type": "null" },
            {
              "allOf": [
                { "$ref": "urn:apkrun:schema:package-record:1#/$defs/updateProvider" },
                { "not": { "properties": { "type": { "const": "local" } } } }
              ]
            }
          ]
        }
      }
    },
    "integration": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "clipboard": { "type": "boolean" },
        "notifications": { "type": "boolean" },
        "links": { "enum": ["ask", "mac", "android"] },
        "files": { "type": "boolean" },
        "sharedFolders": { "enum": ["off", "readOnly", "readWrite"] },
        "microphone": { "type": "boolean" }
      }
    },
    "generated": {
      "type": "object",
      "additionalProperties": false,
      "required": ["formatVersion", "kind", "application", "runtime", "window", "integration"],
      "properties": {
        "formatVersion": { "const": 1 },
        "kind": { "$ref": "#/$defs/kind" },
        "application": {
          "allOf": [
            { "$ref": "#/$defs/application" },
            { "type": "object", "additionalProperties": false, "properties": { "packageId": true, "displayName": true } }
          ]
        },
        "runtime": {
          "allOf": [
            { "$ref": "#/$defs/runtime" },
            { "type": "object", "additionalProperties": false, "properties": { "minimumVersion": true, "launcherAPI": true } }
          ]
        },
        "window": {
          "allOf": [
            { "$ref": "#/$defs/window" },
            { "required": ["mode", "defaultWidth", "defaultHeight", "resizable"] }
          ]
        },
        "updates": {
          "allOf": [
            { "$ref": "#/$defs/updates" },
            { "required": ["authority", "mode", "provider"] },
            {
              "if": { "properties": { "authority": { "const": "apkrun" } } },
              "then": { "properties": { "provider": { "type": "object" } } }
            }
          ]
        },
        "integration": { "$ref": "#/$defs/integration" }
      }
    }
  }
}
```

---

## 3. `bootstrap.json`

### 3.1 Example

The `current/` set of `org.example.notes` 4.5 from [package-metadata-json.md](package-metadata-json.md) §2.1. `setDigest` is computed from the two file digests by [package-store.md](../02-design/package-store.md) §3.3, and the sizes add up to the record's `size`:

```json
{
  "files": [
    {
      "name": "base.apk",
      "sha256": "sha256:0bae9219fead973277b7ef13d8c492caa38a1291b97800f1bee0572ddfb02f03",
      "size": 44900001
    },
    {
      "name": "split_config.arm64_v8a.apk",
      "sha256": "sha256:7f7e67c7500305a893c01de6191c3a73f87822fc8476d1206e7119a1f6b49c0e",
      "size": 3313376
    }
  ],
  "formatVersion": 1,
  "packageId": "org.example.notes",
  "setDigest": "sha256:96bbfcf3145dec90d6fcfbce72677d07cda54ef74eb0e14c6364ba79a92768ad",
  "signers": ["sha256:d43041c5c08759aeb0aa94c1bb854186b4ab1512364f8dc5c1150ae176e3ec56"],
  "versionCode": 45,
  "versionName": "4.5"
}
```

The digest input is these two lines, each ending in `\n`:

```text
base.apk	0bae9219fead973277b7ef13d8c492caa38a1291b97800f1bee0572ddfb02f03
split_config.arm64_v8a.apk	7f7e67c7500305a893c01de6191c3a73f87822fc8476d1206e7119a1f6b49c0e
```

### 3.2 Fields

The values come from the `current/` slot's `artifact.json` ([package-store.md](../02-design/package-store.md) §2.2). For a portable wrapper built from a file, they come from the import ticket's inspected set ([wrapper.md](../02-design/wrapper.md) §10.1).

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `formatVersion` | integer | yes | `1` | the bootstrap format |
| `packageId` | `PackageID` | yes | equals `wrapper.json` `application.packageId` | the package of the set |
| `versionCode` | `VersionCode` | yes | | the set's version |
| `versionName` | string | no | 1–1024 characters | shown as "Includes Notes 4.5" in the approval dialog and screen N. Omitted when the package has none |
| `setDigest` | `SHA256Digest` | yes | recomputable from `files` (B6) | the set digest |
| `signers` | array of `SHA256Digest` | yes | 1–16 items, unique, sorted ascending | the signer set (`ArtifactSet.signerDigests`) |
| `files` | array | yes | 1–256 items: `base.apk` first, then the splits in `artifact.json` order (sorted by split name). Names unique | the APK files in `bootstrap/` |
| `files[].name` | string | yes | `base.apk`, or `split_<splitName>.apk`, split name segments `[A-Za-z][A-Za-z0-9_]*` joined by `.`. At most 255 characters | the file name in `bootstrap/` |
| `files[].size` | integer | yes | 1 to 2 GiB (2147483648). Sum at most 8 GiB | size in bytes |
| `files[].sha256` | `SHA256Digest` | yes | | the file's SHA-256, with the `sha256:` prefix as in `artifact.json`. Set digest lines use the hex part |

- The size limits are the import limits of [package-store.md](../02-design/package-store.md) §4.2.
- Unknown fields are ignored and never written.
- `bootstrap/` holds `bootstrap.json` and exactly the listed files. The launcher sends them in list order and ignores other files.

### 3.3 Semantics

- The bootstrap describes the embedded copy, not the installed app. It never changes after generation, and it goes stale after the first update on the receiving Mac ([wrapper.md](../02-design/wrapper.md) §10.2).
- It is used only when the package is not installed on the receiving Mac, or is `uninstalledKeepingData`. It never updates or downgrades an installed package.
- The new record gets `source.kind` `wrapperBootstrap` and `source.wrapperBundleId` ([package-metadata-json.md](package-metadata-json.md) §2.3.4). Authority, provider, and settings come from `wrapper.json` (§2.4).

### 3.4 Import checks

`importBootstrap(bootstrapJSON, [FileHandle])` on the wrapper endpoint runs these checks in order. The first failure decides. Error types: [error-catalog.md](error-catalog.md) (`BootstrapProblem`, `BootstrapRefusal`).

| # | Check | Failure |
|---|---|---|
| B1 | the wrapper connection is approved (registry state `active`) | `wrapper.bootstrapNotAllowed(.notApproved)` |
| B2 | the package is not installed, or is `uninstalledKeepingData` | `wrapper.bootstrapNotAllowed(.alreadyInstalled)` |
| B3 | the JSON parses, is at most 64 KiB, has a supported `formatVersion`, and passes §3.5 | `wrapper.bootstrapInvalid(.malformed)` |
| B4 | `packageId` equals the registry entry's `packageId` | `wrapper.bootstrapInvalid(.packageMismatch)` |
| B5 | one file handle per `files` item; each copied file has the listed `size` and `sha256`; total at most 8 GiB | count wrong: `.malformed`. Size or digest wrong: `.hashMismatch` |
| B6 | the set digest computed from the copied files equals `setDigest` | `wrapper.bootstrapInvalid(.hashMismatch)` |
| B7 | the inspected APKs have `packageId` and `versionCode`, and the verified signer set equals `signers` | `wrapper.bootstrapInvalid(.packageMismatch)` |
| B8 | the store's intrinsic checks and preview ([package-store.md](../02-design/package-store.md) §4.1, §4.6) | the store's own errors, for example the downgrade error when Android kept newer data |

The store hashes the files while it copies them into `incoming/<ticket>/`. It never trusts the digests in the file without computing them.

### 3.5 JSON Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:wrapper-bootstrap:1",
  "title": "APKRun wrapper bootstrap/bootstrap.json, formatVersion 1",
  "type": "object",
  "required": ["formatVersion", "packageId", "versionCode", "setDigest", "signers", "files"],
  "properties": {
    "formatVersion": { "const": 1 },
    "packageId": { "type": "string", "maxLength": 255, "pattern": "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$" },
    "versionCode": { "type": "integer", "minimum": 0, "maximum": 9223372036854775807 },
    "versionName": { "type": "string", "minLength": 1, "maxLength": 1024 },
    "setDigest": { "$ref": "#/$defs/sha256Digest" },
    "signers": { "type": "array", "minItems": 1, "maxItems": 16, "uniqueItems": true, "items": { "$ref": "#/$defs/sha256Digest" } },
    "files": {
      "type": "array",
      "minItems": 1,
      "maxItems": 256,
      "prefixItems": [
        { "allOf": [ { "$ref": "#/$defs/file" }, { "properties": { "name": { "const": "base.apk" } } } ] }
      ],
      "items": {
        "allOf": [
          { "$ref": "#/$defs/file" },
          { "properties": { "name": { "pattern": "^split_[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*\\.apk$" } } }
        ]
      }
    }
  },
  "$defs": {
    "sha256Digest": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
    "file": {
      "type": "object",
      "required": ["name", "size", "sha256"],
      "properties": {
        "name": { "type": "string", "minLength": 1, "maxLength": 255 },
        "size": { "type": "integer", "minimum": 1, "maximum": 2147483648 },
        "sha256": { "$ref": "#/$defs/sha256Digest" }
      }
    }
  }
}
```

The schema cannot express unique names, the total size, or the set digest. `BootstrapManifest.validate()` checks them in code.

---

## 4. `registry.json`

### 4.1 Example

The Notes wrapper is active. It was generated after the update to 4.5, so its `bootstrap/` holds the set of §3.1. The Chat wrapper is in the middle of a launcher refresh ([wrapper.md](../02-design/wrapper.md) §9.3 steps 4–7):

```json
{
  "denied": [
    {
      "bundleId": "io.apkrun.android.com.example.game",
      "cdhash": "304e06a5696d646237bb2c2896a4b378e32a6d48",
      "until": "2026-10-03T08:00:00.000Z"
    }
  ],
  "schemaVersion": 1,
  "wrappers": [
    {
      "approval": "generated",
      "bookmark": "Ym9vawAABAAAEAAAYXBrcnVuLWV4YW1wbGUtYm9va21hcmstZGF0YQ==",
      "bundleId": "io.apkrun.android.com.example.chat",
      "cdhash": "93213455ba0e5cb1d4bf87d636d312b4f2e81e1f",
      "createdAt": "2026-10-01T08:05:00.000Z",
      "customization": { "displayName": null, "iconFile": null },
      "displayName": "Chat",
      "fileName": "Chat",
      "formatVersion": 1,
      "iconDigest": "sha256:81d7d8b42e06b5e81db917db0357064ce9df050406572974c40190fdb5dd3cbb",
      "kind": "local",
      "lastValidatedAt": "2026-10-02T08:00:00.000Z",
      "launcherAPI": "1.0",
      "launcherVersion": "1.0.0",
      "packageId": "com.example.chat",
      "path": "/Users/me/Applications/Chat.app",
      "pendingCdhash": "6c1bf4509f769826dae417aa3e049d558330f291",
      "refreshedAt": null,
      "stagingPath": "/Users/me/Applications/.apkrun-79678b0d-26a3-424f-b31c-8b3b547b5c10/Chat.app",
      "state": "refreshing"
    },
    {
      "approval": "generated",
      "bookmark": "Ym9vawAABAAAEAAAYXBrcnVuLWV4YW1wbGUtYm9va21hcmstZGF0YQ==",
      "bundleId": "io.apkrun.android.org.example.notes",
      "cdhash": "56f0ed17c766013762ed1638d09318f9536bf76e",
      "createdAt": "2026-10-02T09:30:00.000Z",
      "customization": { "displayName": null, "iconFile": null },
      "displayName": "Notes",
      "fileName": "Notes",
      "formatVersion": 1,
      "iconDigest": "sha256:384253ab5579b820f2f1880480c879bdd0eae50a86333583a51c5c191ceb5edc",
      "kind": "portable",
      "lastValidatedAt": null,
      "launcherAPI": "1.0",
      "launcherVersion": "1.0.0",
      "packageId": "org.example.notes",
      "path": "/Users/me/Applications/Notes.app",
      "refreshedAt": null,
      "state": "active"
    }
  ]
}
```

### 4.2 Fields

Top level:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | `1` | the file schema (§6.3) |
| `wrappers` | array of entries | yes | 0–1000 items, sorted by `bundleId`. One entry per bundle ID (ignoring case) and per package ID | the registered wrappers |
| `denied` | array of denied entries | yes | 0–1000 items, sorted by `bundleId`, then `cdhash` | refused wrappers (§4.4) |

Wrapper entry. **Nullable** fields are always present and may be `null`:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `bundleId` | `BundleID` | yes | equals `map(packageId)` | the bundle ID and code-signing identifier |
| `packageId` | `PackageID` | yes | | the only package this wrapper may open (NFR-SEC-07) |
| `kind` | enum | yes | `local`, `portable`, `distribution` | `APKRunWrapperKind` |
| `state` | enum | yes | `active`, `pending`, `refreshing` | §4.3 |
| `path` | string | yes | absolute, ends in `.app`, at most 1024 UTF-8 bytes | last known location |
| `bookmark` | `Bookmark` | `active`, `refreshing` only | | bookmark of `path`; follows moves and renames |
| `stagingPath` | string | `pending`, `refreshing` only | absolute, ends in `.app`, at most 1024 bytes | `pending`: `Wrappers/staging/<uuid>/`. `refreshing`: `<parent>/.apkrun-<uuid>/`. Recovery deletes it ([wrapper.md](../02-design/wrapper.md) §6.2) |
| `cdhash` | `CDHash` | yes | | value of the `.wrapper(bundleID)` endpoint requirement |
| `pendingCdhash` | `CDHash` | exactly when `refreshing` | differs from `cdhash` | the new bundle's cdhash. Both are accepted until the refresh ends |
| `launcherVersion` | `AppVersion` | yes | | `APKRunLauncherVersion` |
| `launcherAPI` | `APIVersion` | yes | | `APKRunLauncherAPI` |
| `formatVersion` | integer | yes | ≥ 1 | `APKRunWrapperFormat` |
| `fileName` | string | yes | 1–251 UTF-8 bytes, no `/` | file name without `.app`. Updated on rename |
| `displayName` | string | yes | 1–1024 characters | `CFBundleDisplayName` |
| `customization.displayName` | string, nullable | yes | 1–1024 characters | the user's custom name. `null` means the Android label |
| `customization.iconFile` | string, nullable | yes | `<bundleId>.png` | custom icon in `Wrappers/icons/`. `null` means the Android icon |
| `iconDigest` | `SHA256Digest`, nullable | yes | | SHA-256 of the 1024 px master in the bundle ([wrapper.md](../02-design/wrapper.md) §8.5). `null` with a custom icon, which is never compared |
| `approval` | enum | yes | `generated`, `user` | `generated`: apkrund built it on this Mac. `user`: approved ([wrapper.md](../02-design/wrapper.md) §7.3) |
| `createdAt` | `Date` | yes | | when the entry was created |
| `refreshedAt` | `Date`, nullable | yes | ≥ `createdAt` | the last finished refresh. `null` before the first |
| `lastValidatedAt` | `Date`, nullable | yes | | last validation by the run at apkrund start + 60 s, by `apkrun doctor`, or by `apkrun wrapper verify` ([wrapper.md](../02-design/wrapper.md) §9.1). Cached `listWrappers` and launch checks do not write it. `null` before the first |

### 4.3 Entry states

| State | Set by | Required fields | Absent fields | Next |
|---|---|---|---|---|
| `pending` | generation step 10 ([wrapper.md](../02-design/wrapper.md) §6.2) | `stagingPath`. `path` is the planned final location | `bookmark`, `pendingCdhash` | `active` at step 12, or after `placeStagedWrapper` (which sets `path`). Recovery activates the entry if the final bundle has `cdhash`, else drops it |
| `active` | generation step 12, approval, end of refresh, recovery | `bookmark` | `stagingPath`, `pendingCdhash` | `refreshing`, or removal |
| `refreshing` | refresh step 4 ([wrapper.md](../02-design/wrapper.md) §9.3) | `bookmark`, `stagingPath`, `pendingCdhash` | — | `active` at step 7: `cdhash` ← `pendingCdhash`, new `refreshedAt` and `bookmark`, and the new bundle's `launcherVersion`, `launcherAPI`, `formatVersion`, `fileName`, `displayName`, `customization`, `iconDigest`. Recovery completes the refresh if the bundle's cdhash equals `pendingCdhash`, else returns to `active` unchanged |

- During `refreshing` the other fields keep their old values, so a rollback only removes `pendingCdhash` and `stagingPath`.
- A moved or renamed bundle (`WrapperState.moved`) updates `path`, `bookmark`, and `fileName`.
- `WrapperStatus` is computed on demand and never stored ([wrapper.md](../02-design/wrapper.md) §9.1).

### 4.4 Denied entries

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `bundleId` | `BundleID` | yes | | the refused wrapper |
| `cdhash` | `CDHash` | yes | | the refused bundle's cdhash. Another build of the same bundle ID is not denied |
| `until` | `Date` | yes | 24 h after the decision | until when a new approval request is refused at once ([wrapper.md](../02-design/wrapper.md) §7.3 step 3) |

- Expired entries are removed at the next write. When the list is full, the entry with the earliest `until` is removed.
- A denied entry also blocks `apkrun wrapper approve` ([wrapper.md](../02-design/wrapper.md) §12.1). It ends when it expires or when the user clears it in Settings → Privacy.
- At most one denied entry exists per bundle ID and cdhash. A new refusal of the same pair replaces `until`.

### 4.5 JSON Schema

This schema is the writer's contract. Readers apply §5.3.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:wrapper-registry:1",
  "title": "APKRun Wrappers/registry.json, schemaVersion 1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "wrappers", "denied"],
  "properties": {
    "schemaVersion": { "const": 1 },
    "wrappers": { "type": "array", "maxItems": 1000, "items": { "$ref": "#/$defs/entry" } },
    "denied": { "type": "array", "maxItems": 1000, "items": { "$ref": "#/$defs/denied" } }
  },
  "$defs": {
    "packageId": { "type": "string", "maxLength": 255, "pattern": "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$" },
    "bundleId": { "type": "string", "maxLength": 255, "pattern": "^io\\.apkrun\\.android\\.[A-Za-z0-9.-]+$" },
    "cdhash": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
    "sha256Digest": { "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" },
    "date": { "type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$" },
    "appPath": { "type": "string", "minLength": 6, "maxLength": 1024, "pattern": "^/.*[^/]\\.app$" },
    "label": { "type": "string", "minLength": 1, "maxLength": 1024 },
    "entry": {
      "type": "object",
      "additionalProperties": false,
      "required": ["bundleId", "packageId", "kind", "state", "path", "cdhash", "launcherVersion", "launcherAPI", "formatVersion", "fileName", "displayName", "customization", "iconDigest", "approval", "createdAt", "refreshedAt", "lastValidatedAt"],
      "properties": {
        "bundleId": { "$ref": "#/$defs/bundleId" },
        "packageId": { "$ref": "#/$defs/packageId" },
        "kind": { "enum": ["local", "portable", "distribution"] },
        "state": { "enum": ["active", "pending", "refreshing"] },
        "path": { "$ref": "#/$defs/appPath" },
        "bookmark": { "type": "string", "minLength": 4, "maxLength": 10924, "pattern": "^[A-Za-z0-9+/]+={0,2}$" },
        "stagingPath": { "$ref": "#/$defs/appPath" },
        "cdhash": { "$ref": "#/$defs/cdhash" },
        "pendingCdhash": { "$ref": "#/$defs/cdhash" },
        "launcherVersion": { "type": "string", "maxLength": 32, "pattern": "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" },
        "launcherAPI": { "type": "string", "maxLength": 16, "pattern": "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" },
        "formatVersion": { "type": "integer", "minimum": 1 },
        "fileName": { "type": "string", "minLength": 1, "maxLength": 251, "pattern": "^[^/]+$" },
        "displayName": { "$ref": "#/$defs/label" },
        "customization": {
          "type": "object",
          "additionalProperties": false,
          "required": ["displayName", "iconFile"],
          "properties": {
            "displayName": { "oneOf": [ { "type": "null" }, { "$ref": "#/$defs/label" } ] },
            "iconFile": { "oneOf": [ { "type": "null" }, { "type": "string", "pattern": "^io\\.apkrun\\.android\\.[A-Za-z0-9.-]+\\.png$" } ] }
          }
        },
        "iconDigest": { "oneOf": [ { "type": "null" }, { "$ref": "#/$defs/sha256Digest" } ] },
        "approval": { "enum": ["generated", "user"] },
        "createdAt": { "$ref": "#/$defs/date" },
        "refreshedAt": { "oneOf": [ { "type": "null" }, { "$ref": "#/$defs/date" } ] },
        "lastValidatedAt": { "oneOf": [ { "type": "null" }, { "$ref": "#/$defs/date" } ] }
      },
      "allOf": [
        {
          "if": { "properties": { "state": { "const": "active" } } },
          "then": { "required": ["bookmark"], "not": { "anyOf": [ { "required": ["stagingPath"] }, { "required": ["pendingCdhash"] } ] } }
        },
        {
          "if": { "properties": { "state": { "const": "pending" } } },
          "then": { "required": ["stagingPath"], "not": { "anyOf": [ { "required": ["bookmark"] }, { "required": ["pendingCdhash"] } ] } }
        },
        {
          "if": { "properties": { "state": { "const": "refreshing" } } },
          "then": { "required": ["bookmark", "stagingPath", "pendingCdhash"] }
        }
      ]
    },
    "denied": {
      "type": "object",
      "additionalProperties": false,
      "required": ["bundleId", "cdhash", "until"],
      "properties": {
        "bundleId": { "$ref": "#/$defs/bundleId" },
        "cdhash": { "$ref": "#/$defs/cdhash" },
        "until": { "$ref": "#/$defs/date" }
      }
    }
  }
}
```

`WrapperRegistry` checks in code what the schema cannot express: `bundleId` equals `map(packageId)`, the uniqueness and sort rules of §4.2, `pendingCdhash` ≠ `cdhash`, `iconFile` equals `<bundleId>.png`, and the byte limits.

---

## 5. Validation rules

### 5.1 `wrapper.json`

| When | Checks | Failure |
|---|---|---|
| Launcher startup step 1 | readable, at most 64 KiB, passes the root schema (§2.7); X1, X2 | screen D, `wrapper.wrapperDamaged(detail)` ([wrapper.md](../02-design/wrapper.md) §5.4) |
| Approval step 1, `verifyWrapper`, `approveWrapper` | the same, plus X3–X6 | `wrapper.bundleInvalid(URL, reason)` |
| Generation (T0 and a debug assertion) | passes `$defs/generated` | a programming error: `runtime.internal` |
| First record (§2.4) | each preference key alone | the key is ignored and logged |

A modified `wrapper.json` also breaks the resource seal. `apkrun doctor --deep` reports `signatureInvalid` ([wrapper.md](../02-design/wrapper.md) §9.1).

### 5.2 `bootstrap.json`

| When | Checks | Failure |
|---|---|---|
| Launcher, before it offers **Install from This App** | exists, parses, names the same `packageId` | screen N without the install action; logged |
| `importBootstrap` | B1–B8 (§3.4) | as listed there |
| Generation (T0 and a debug assertion) | §3.5 and the code checks, set digest recomputed | `runtime.internal` |

### 5.3 `registry.json`

| Problem at load | Behavior |
|---|---|
| File missing | an empty registry; no wrapper is authorized. Home offers **Re-register Mac Apps** ([wrapper.md](../02-design/wrapper.md) §7.2) |
| Not a JSON object, over 4 MiB, no integer `schemaVersion`, or `wrappers`/`denied` not an array | renamed to `registry.json.corrupt-<time>` (UTC, for example `20261002T091203Z`). `wrapper.registryUnavailable`; health `wrappers.registry` warns. No wrapper is authorized. The next write starts a new file |
| Older `schemaVersion` | migrated (§6.3) |
| Newer `schemaVersion` | WrapperCore starts degraded with `maintenance.dataCreatedByNewerVersion`. Never written. No wrapper is authorized. The generic launcher still works |
| One entry breaks §4.2 or the code checks | the entry is ignored and logged (`wrappers.registry` warns). Its wrapper needs approval again. Dropped at the next write |
| Unknown field | ignored, dropped at the next write |

Writes use atomic replace: temporary file, `fsync`, rename ([wrapper.md](../02-design/wrapper.md) §7.2). Only `WrapperRegistry` writes, one change at a time. A write that would break §4.5 is a programming error and is refused.

---

## 6. Versioning

### 6.1 `wrapper.json`

See §2.6. `formatVersion` 1 is the only format in v1.

### 6.2 `bootstrap.json`

Same rules as §2.6. A bootstrap format the receiving APKRun does not know fails at B3. Its `runtime.minimumVersion` normally stops the wrapper earlier, at screen V.

### 6.3 `registry.json`

`registry.json` follows the host data file rules of [runtime-maintenance.md](../02-design/runtime-maintenance.md) §5:

- Every change raises `schemaVersion`, including additive ones. The current value is `dataSchemas.wrapperRegistry` in `components.json`.
- At load, an older file is kept as `registry.v<old>.json`, migrated in memory, validated, and replaced with `FileManager.replaceItemAt`. The backup is deleted after 90 days. A failure starts WrapperCore degraded with `maintenance.schemaMigrationFailed`.
- There is no journal. `pending` and `refreshing` are the journal for generation and refresh ([wrapper.md](../02-design/wrapper.md) §6.2). Recovery runs after the migration.

---

## 7. Writers and readers

| File | Writer | Readers |
|---|---|---|
| `wrapper.json` | `AppWrapperGenerator`: generation step 5 and every refresh | `APKRunLauncher` (startup step 1); `WrapperApprovalService`, `WrapperValidator`; the store through RuntimeHost (first record only) |
| `bootstrap.json` | `AppWrapperGenerator`: generation step 8 | `APKRunLauncher` (screen N, before `importBootstrap`); RuntimeHost `importBootstrap` (§3.4) |
| `registry.json` | `WrapperRegistry` only: generation steps 10 and 12, `placeStagedWrapper`, refresh steps 4 and 7, approval step 5, moves found by `WrapperValidator`, `lastValidatedAt` updates, `removeWrapper`, uninstall with Trash, **Re-register Mac Apps**, recovery, pruning | `WrapperRegistry` (at apkrund start, then from memory; `requestEndpoint` uses memory); DiagnosticsCore (§8) |

No other process reads `registry.json`. APKRun.app and the CLI use `listWrappers` and `wrapperInfo` ([wrapper.md](../02-design/wrapper.md) §12.1).

---

## 8. Diagnostics and privacy

- The diagnostics bundle includes `registry.json` with `path` and `stagingPath` reduced to their last component and `bookmark` removed ([diagnostics.md](../02-design/diagnostics.md) §6.2). A host-only bundle omits it.
- `wrapper.json` and `bootstrap.json` are not collected. `apkrun wrapper verify --json` shows their identity fields.
- Logs use `privacy: .public` for package IDs, bundle IDs, and cdhashes, and `.private` for paths ([wrapper.md](../02-design/wrapper.md) §14).
- `wrapper.json` never contains a credential. A GitHub token stays in the creator's Keychain, and a Local provider is never written (§2.5).

---

## 9. Tests and fixtures

Fixtures:

- `Tests/Fixtures/wrappers/wrapper-json/valid/*.json` and `invalid/*.json`. The invalid set has one broken rule per file, named after the rule (`x1-package-mismatch.json`, `format-2.json`).
- `Tests/Fixtures/wrappers/bootstrap-json/valid/*.json` and `invalid/*.json`. The valid set includes §3.1, with test files built from `Tests/Fixtures/apks/`.
- `Tests/Fixtures/schemas/wrapperRegistry/v1.json` and `v1.expected.json` ([runtime-maintenance.md](../02-design/runtime-maintenance.md) §5), with `valid/` and `invalid/`.

Tests:

- T0: golden files: a fixed `WrapperConfiguration` gives byte-identical `wrapper.json` and `bootstrap.json`. Valid schema fixtures pass, invalid ones fail, generated files pass `$defs/generated`, and an unknown `formatVersion` is rejected. Cross-checks X1–X6, the compatibility matrix of [runtime-api.md](runtime-api.md) §2.4, the mapping of §2.4, and bootstrap checks B3–B7.
- T0: registry state rules (§4.3), code checks, sorting, denied expiry and pruning, and migration.
- T1: atomic writes, a renamed corrupt file, a bad entry ignored, and `pending` and `refreshing` recovery at every step.
- T2: portable first run in a second user account: approval, bootstrap import, and the record's `source`, authority, and settings.
