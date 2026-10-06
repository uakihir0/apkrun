# AndroidImageManifest and Inventory

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [runtime-image-manifest.md](runtime-image-manifest.md) §4 (`provenance`), [../01-architecture/modules.md](../01-architecture/modules.md) (ImageCore), [../04-plan/traceability.md](../04-plan/traceability.md) FR-IMG-02 |

This document defines two build-time files:

- `inventory.json` says **what is in** an Android build (#008). A tool writes it. Nobody edits it.
- `android-image.json`, the `AndroidImageManifest`, says **what each file is for** (#009). A tool generates it, a human reviews it, and it is committed.

Both files live in the source tree. Neither is shipped to users. The runtime image bundle carries only a copy of the manifest's `source` and `android` blocks, in its `provenance` block ([runtime-image-manifest.md](runtime-image-manifest.md) §4).

---

## 1. Rules

- No code, Swift or Python, opens an Android image file by a hard-coded name. File names come from the inventory, then this manifest, then the runtime image manifest ([../02-design/android-image.md](../02-design/android-image.md) §1).
- The inventory classifies files **by content**. A file name is only a hint (§4.4).
- Original downloaded files are never modified. Every tool opens them read-only. Derived files go to `Images/work/<buildId>/` or into the bundle.
- ImageCore never parses AOSP outputs. It reads this manifest only as provenance and in tests (§9).
- One manifest describes one Android build: one `buildId`, one target, one architecture.

## 2. Files and locations

| Path (source tree) | Committed | Content |
|---|---|---|
| `Images/manifests/<buildId>/inventory.json` | yes | the inventory (§4) |
| `Images/manifests/<buildId>/android-image.json` | yes | the manifest (§5–§6) |
| `Images/work/<buildId>/download/` | no (git-ignored) | the downloaded archives and `fetch.json` (name, size, SHA-256 per download; branch marked caller-asserted) |
| `Images/work/<buildId>/boot/`, `disks/`, `bundle/` | no | outputs of `extract`, `disks`, and `bundle` (§9) |
| `Images/tools/schemas/android-image-manifest.schema.json` | yes | the JSON Schema of §7, byte for byte |
| `Images/tools/layouts/<deviceFamily>.json` | yes | the disk plan, console port plan, and bootconfig baseline. It refers to partitions, never to files (§9) |
| `Images/tools/tests/fixtures/manifests/invalid/` | yes | invalid manifests with their expected messages (§12) |

- `Images/manifests/` holds only these two files per build. Runtime image manifests are built into bundles under `Images/work/<buildId>/bundle/` and are not committed.
- The pinned build for M1–M4 is `16373615` (branch `aosp-android-latest-release`, target `aosp_cf_arm64_only_phone-userdebug`, Android 17, API 37), per [ADR-0003](../01-architecture/decisions/0003-cuttlefish-base-image.md). APKRun's own builds (M5+) use the same pipeline ([../02-design/android-image.md](../02-design/android-image.md) §11.5).

## 3. Tooling

The tools are Python 3.12 in `Images/tools/` (package `apkrun_image`, pinned `lz4`, `cryptography`, `jsonschema`, `pytest`). Run them from the repository root.

| Command | Reads | Writes | Task |
|---|---|---|---|
| `python3 -m apkrun_image fetch --branch … --target … --build <buildId> --artifact '<glob>' --out Images/work/<buildId>/download/` | Android Build API v4 (key from `APKRUN_ANDROID_BUILD_API_KEY`) | archives, `fetch.json` | #008 |
| `scripts/inventory-cuttlefish.py <zip or directory> [--out inventory.json]` | an archive or an unpacked directory | `inventory.json` (stdout without `--out`) | #008 |
| `python3 -m apkrun_image manifest --inventory Images/manifests/<buildId>/inventory.json --out Images/manifests/<buildId>/android-image.json` | the inventory, and the archive for the header checks | a draft manifest for review | #009 |
| `python3 -m apkrun_image manifest --check Images/manifests/<buildId>/android-image.json [--no-files]` | the manifest, the inventory, the archive | nothing. Exit 0, or 1 with every failed check (§8) | #009 |
| `python3 -m apkrun_image extract --manifest … --out Images/work/<buildId>/boot/` | manifest `roles` | kernel, ramdisk, cmdline, vendor bootconfig, `extraction.json` | #010 |
| `python3 -m apkrun_image disks --manifest … --layout layouts/<deviceFamily>.json --out Images/work/<buildId>/disks/` | manifest `artifacts`, `blankPartitions`, `logicalPartitions` | `os.img`, `persistent.img`, `userdata.img`, `disks.json` | #011 |
| `python3 -m apkrun_image bundle --manifest … --layout … --reference … --image-version … --sign-key … --out …` | everything above | the runtime image bundle ([runtime-image-manifest.md](runtime-image-manifest.md) §3) | #065 |
| `python3 -m apkrun_image inspect <file>` | any image file | a human-readable dump (headers, GPT, sparse chunks) | tooling |

- The `inventory.py` module does the work behind `scripts/inventory-cuttlefish.py`, which is a thin wrapper. `manifest.py` holds the model, the schema validation, and the semantic checks.
- Every command that takes `--manifest` runs the checks of §8 first and stops on the first failure.
- Tools find an archive at `Images/work/<buildId>/download/<source.archives[].name>`. `--source <zip or directory>` overrides the location. The archive is re-hashed and must match `source.archives`.

## 4. `inventory.json`

### 4.1 Complete example

Shortened to four files. The real file lists every file in the archive.

```json
{
  "files": [
    {
      "details": {
        "values": {
          "config": "phone",
          "gfxstream": "supported"
        }
      },
      "kind": "text",
      "path": "android-info.txt",
      "probablePurpose": "device information (android-info.txt key/values)",
      "sha256": "8b2d6928cf1159bce2a08e267a8746f23e400b4acea83de4163b396145e972f2",
      "size": 42
    },
    {
      "details": {
        "avbFooter": {
          "originalSize": 44040192,
          "vbmetaOffset": 44040192,
          "vbmetaSize": 2432,
          "version": "1.0"
        },
        "bootKind": "boot",
        "cmdline": "",
        "headerVersion": 4,
        "kernelSize": 43581440,
        "osVersion": {
          "release": "17.0.0",
          "securityPatch": "2026-09"
        },
        "ramdiskSize": 0
      },
      "kind": "bootImage",
      "path": "boot.img",
      "probablePurpose": "boot partition (kernel)",
      "sha256": "4509beb0ab401d71fa4a5cd94a55c9a74f13332776ae4019c5bfc4c2005157ff",
      "size": 67108864
    },
    {
      "details": {
        "magic": "1f2003d5ff4300d1"
      },
      "kind": "unknown",
      "path": "bootloader",
      "probablePurpose": "unknown",
      "sha256": "3b4a12881d11f33cff968a24d7c53723a8232cde9a8d91e29fdbd6a95ae6adf0",
      "size": 4194304
    },
    {
      "details": {
        "blockSize": 4096,
        "chunkCount": 1873,
        "content": {
          "details": {
            "blockDeviceSize": 7516192768,
            "logicalPartitions": [
              { "group": "google_dynamic_partitions_a", "name": "system_a", "size": 897581056 },
              { "group": "google_dynamic_partitions_a", "name": "vendor_a", "size": 150994944 }
            ],
            "metadataSlots": 2
          },
          "kind": "dynamicPartitions"
        },
        "logicalSize": 7516192768,
        "totalBlocks": 1835008
      },
      "kind": "sparse",
      "path": "super.img",
      "probablePurpose": "super partition (dynamic partitions: system_a, vendor_a)",
      "sha256": "73d1b1b1bc1dabfb97f216d897b7968e44b06457920f00f2dc6c1ed3be25ad4c",
      "size": 1879048192
    }
  ],
  "generator": "apkrun_image.inventory 0.1.0",
  "schemaVersion": 2,
  "source": {
    "branch": "aosp-android-latest-release",
    "branchProvenance": "caller-asserted",
    "buildId": "16373615",
    "name": "aosp_cf_arm64_only_phone-img-16373615.zip",
    "sha256": "4a70fe9aa6436e02c2dea340fbd1e352e4ef2d8ce6ca52ad25d4b95471fc8bf2",
    "size": 1476395008,
    "target": "aosp_cf_arm64_only_phone-userdebug",
    "type": "zip"
  }
}
```

### 4.2 Top level

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | `2` | format version of the inventory |
| `generator` | string | yes | `apkrun_image.inventory <version>` | the tool and its version. No time stamp |
| `source` | object | yes | see below | the input that was scanned |
| `source.type` | string | yes | `zip` or `directory` | the input kind; a download directory with `fetch.json` is represented as its archive |
| `source.name` | string | yes | a base name, never an absolute path | the archive file name, or the directory name |
| `source.size` | integer | for `zip` | bytes | archive size |
| `source.sha256` | string | for `zip` | 64 lowercase hex | archive hash |
| `source.branch` | string | when `fetch.json` is present | non-empty | the branch supplied to `fetch` |
| `source.branchProvenance` | string | with `source.branch` | `caller-asserted` | the Build API request is keyed by build ID and target; the branch is not independently confirmed |
| `source.target` | string | when `fetch.json` is present | non-empty | the target supplied to `fetch` |
| `source.buildId` | string | when `fetch.json` is present | non-empty | the build ID supplied to `fetch` |
| `files` | array of entry (§4.3) | yes | sorted by `path`, byte order of UTF-8 | one entry per regular file. Directories are not listed |

### 4.3 File entry

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `path` | string | yes | relative, `/`-separated, as stored in the archive | the file |
| `size` | integer | yes | bytes | file size |
| `sha256` | string | yes | 64 lowercase hex | file hash |
| `kind` | string | yes | one of §4.4 | what the content is |
| `probablePurpose` | string | yes | free text for humans | derived from `kind` plus `details`, never from the name alone. Tools never parse it |
| `nameMismatch` | boolean | no | present only when `true` | the name suggests another kind (§4.6) |
| `details` | object | yes | per kind (§4.4). `{}` when there is nothing to record | the parsed header fields |

### 4.4 Kinds and details

Detection follows [../02-design/android-image.md](../02-design/android-image.md) §3.1. The first matching test wins, in this order.

| `kind` | Test | `details` fields |
|---|---|---|
| `bootImage` | `ANDROID!` at offset 0 | `headerVersion` (offset 40), `kernelSize`, `ramdiskSize`, `osVersion` {`release`, `securityPatch` `YYYY-MM`}, `cmdline`, `bootKind`: `boot` (kernel size > 0) or `init_boot` (kernel size 0, ramdisk > 0), optional `bootSignatureSize` for a bounded v4 signature |
| `vendorBootImage` | `VNDRBOOT` at offset 0 | header version 3 or 4; ramdisk and DTB bounds are checked for both. V4 also records `pageSize`, `cmdline`, `dtbSize`, `ramdisks` [{`name`, `type` `NONE`\|`PLATFORM`\|`RECOVERY`\|`DLKM`, `size`}], and `bootconfigSize` |
| `vbmeta` | `AVB0` at offset 0 | `algorithm`, `rollbackIndex`, `flags`, `descriptors` [{`type` `hash`\|`hashtree`\|`chainPartition`\|`property`\|`kernelCmdline`, `partition` (for hash, hashtree, chain)}] |
| `sparse` | little-endian `0xED26FF3A` at offset 0 | `blockSize`, `totalBlocks`, `logicalSize` (= `blockSize` × `totalBlocks`), `chunkCount`, `content` {`kind`, `details`}: the detection result of the unsparsed stream (`dynamicPartitions`, `filesystem`, or `unknown`) |
| `dynamicPartitions` | liblp geometry magic at offset 4096 | `logicalPartitions` [{`name`, `size`, `group`}], `blockDeviceSize`, `metadataSlots` |
| `filesystem` | ext4 `0xEF53` at 1024+56, erofs `0xE0F5E1E2` at 1024, f2fs `0xF2F52010` at 1024 | `type` `ext4`\|`erofs`\|`f2fs`, `size` (from the superblock) |
| `text` | valid UTF-8, no NUL byte, at most 1 MiB | `values` {key: value} when every non-empty, non-`#` line is `key=value` (android-info.txt). Otherwise `lines` [string] (fastboot-info.txt) |
| `unknown` | anything else | `magic`: the first 8 bytes as lowercase hex (fewer for shorter files) |

- Any image kind may also carry `avbFooter` {`originalSize`, `vbmetaOffset`, `vbmetaSize`, `version`}, when a valid, bounded `AVBf` footer is in the last 64 bytes. Footer integers use big-endian byte order.
- Unknown files are listed. They are never dropped.
- Sparse images are unsparsed as a stream for detection. Nothing is written to disk.

### 4.5 Input bounds and stability

Inventory inputs are untrusted. ZIP processing applies these fixed limits before
allocating the central-directory entry list or decompressing members:

| Limit | Maximum |
|---|---:|
| ZIP archive size | 16 GiB |
| ZIP entries | 4096 |
| ZIP central directory | 64 MiB |
| ZIP64 end record | 1 MiB |
| One file, in an archive or directory | 16 GiB |
| Total uncompressed ZIP data or directory file data | 64 GiB |

Build API metadata is also bounded: one JSON response may be at most 1 MiB,
one listing may contain at most 100 pages, and each page token may be at most
4096 characters. Artifact sizes must be non-negative integral byte counts no
larger than 16 GiB; fractional JSON numbers are rejected. The fetch CLI
requires HTTPS for API and artifact URLs. Local test APIs may explicitly opt
into loopback HTTP; each redirect is checked, loopback redirects remain on
the same origin, and HTTPS cannot redirect to HTTP.

The ZIP end records provide the central-directory bounds and declared count.
Before `zipfile` materializes any entries, the tool caps the central-directory
and ZIP64 end-record scan sizes, rejects ZIP64 extensible data sectors (which
the pinned Python reader does not safely support), then scans the central
directory one fixed-size record at a time, counts actual entries, rejects the
4097th, and checks the actual count against the end record. This also rejects
archives that underreport their entry count. ZIP64 self-extracting prefixes are
handled by locating the bounded end record relative to its locator. ZIP member
sizes are checked before opening them, and decompression stops if a member
exceeds its declared or allowed size.
Directory inputs reject symbolic links, open each member relative to a
directory descriptor without following symlink components, and verify file
identity and timestamps before and after hashing and classification. Hashes
and parsed details therefore describe the same stable file.

An inventory output path must resolve outside its input directory. This check
happens before creating the output parent, so a rejected output path leaves no
directories behind.

Concurrent fetches that share a parent directory are serialized by locking
that directory's descriptor. This avoids a replaceable sidecar lock path; the
trade-off is that separate output directories with the same parent wait for
one another.

### 4.6 Name hints

`nameMismatch` is the only place where a name is used. The base name without `.img` is looked up here. A name that is not in the table never mismatches.

| Name | Expected content |
|---|---|
| `boot` | `bootImage` with `bootKind` `boot` |
| `init_boot` | `bootImage` with `bootKind` `init_boot` |
| `vendor_boot` | `vendorBootImage` |
| `vbmeta`, `vbmeta_*` | `vbmeta` |
| `super` | `dynamicPartitions`, or `sparse` with that content |
| `userdata` | `filesystem`, or `sparse` with that content |

### 4.7 Determinism

The acceptance of #008 is that a second run gives byte-identical output. So the writer uses UTF-8, sorted keys, 2-space indentation, and a trailing newline. It writes no time stamps and no absolute paths. `files` is sorted by `path`. When an input directory contains one archive and its `fetch.json`, the inventory verifies the archive against that record and carries the branch, target, and build ID into `source`; the sidecar itself is not an archive entry.

## 5. `android-image.json`: complete example

This is the generated manifest for the pinned build `16373615`. It matches
[`Images/manifests/16373615/android-image.json`](../../Images/manifests/16373615/android-image.json)
and the committed inventory. The blank partition sizes remain placeholders
until #011 reads their actual values from the #064 reference capture.

```json
{
  "android": {
    "release": "17",
    "sdk": 37,
    "securityPatch": "2026-06",
    "variant": "userdebug"
  },
  "androidInfo": {
    "config": "phone",
    "gfxstream": "supported",
    "gfxstream_gl_program_binary_link_status": "supported"
  },
  "architecture": "arm64",
  "artifacts": [
    {
      "file": "boot.img",
      "id": "boot",
      "kind": "bootImage",
      "partition": "boot",
      "sha256": "a8fb0875277c99d40154e03416010c496c22395bb4dd6b399ddeef69f5a833ac",
      "size": 67108864
    },
    {
      "file": "cuttlefish_example_custom.img",
      "id": "custom",
      "kind": "filesystem",
      "partition": "custom",
      "sha256": "3d17578db83de489aafbd421d98d2596cf4d486639c2802f4df7e9ac9e231847",
      "size": 1048576
    },
    {
      "file": "init_boot.img",
      "id": "init_boot",
      "kind": "bootImage",
      "partition": "init_boot",
      "sha256": "df1a2fc8aa21b5df13a2dcea50cdf90ac2ad222f19fb5a70877a16130e374e54",
      "size": 8388608
    },
    {
      "file": "super.img",
      "id": "super",
      "kind": "sparse",
      "partition": "super",
      "sha256": "54052b9f2d0f463e995c90b9eecc4b3a8aad29d110044aac9c2170108feb5a05",
      "size": 1746554644
    },
    {
      "file": "userdata.img",
      "id": "userdata",
      "kind": "sparse",
      "partition": "userdata",
      "sha256": "f61bf108a6681bfd40f43e288a68bc623f1218d6d0d1840be87cb278b6093034",
      "size": 2249012
    },
    {
      "file": "vbmeta.img",
      "id": "vbmeta",
      "kind": "vbmeta",
      "partition": "vbmeta",
      "sha256": "f2b8f369dd85659180b6bb10abf23845ac0d61de0cd6c17d883fc342e23867d8",
      "size": 12288
    },
    {
      "file": "vbmeta_system.img",
      "id": "vbmeta_system",
      "kind": "vbmeta",
      "partition": "vbmeta_system",
      "sha256": "8cd7110a0a15dbde66c91789e227bfe6a67b8381466815185a9bb5a0b161173d",
      "size": 4096
    },
    {
      "file": "vbmeta_system_dlkm.img",
      "id": "vbmeta_system_dlkm",
      "kind": "vbmeta",
      "partition": "vbmeta_system_dlkm",
      "sha256": "1c86b6c6b979860ee5e9f67387f0f152c4db39274520de812858ce3b6fec989a",
      "size": 4096
    },
    {
      "file": "vbmeta_vendor_dlkm.img",
      "id": "vbmeta_vendor_dlkm",
      "kind": "vbmeta",
      "partition": "vbmeta_vendor_dlkm",
      "sha256": "beeda4df61c649a7c74a5a296d910b310b9abb26bd2d81ff9b634008148dbc11",
      "size": 4096
    },
    {
      "file": "vendor_boot.img",
      "id": "vendor_boot",
      "kind": "vendorBootImage",
      "partition": "vendor_boot",
      "sha256": "02b2af631eb4868ea2163b9de0773ab3b17bf1f5ddca5ab4e2a0258777f46f3f",
      "size": 67108864
    }
  ],
  "blankPartitions": [
    {
      "partition": "misc",
      "size": 1048576
    },
    {
      "partition": "metadata",
      "size": 67108864
    },
    {
      "partition": "frp",
      "size": 1048576
    }
  ],
  "deviceFamily": "cuttlefish-phone-arm64",
  "logicalPartitions": [
    {
      "filesystem": "erofs",
      "name": "odm_a",
      "size": 520192
    },
    {
      "filesystem": "erofs",
      "name": "odm_dlkm_a",
      "size": 348160
    },
    {
      "filesystem": "erofs",
      "name": "product_a",
      "size": 232157184
    },
    {
      "filesystem": "erofs",
      "name": "system_a",
      "size": 959066112
    },
    {
      "filesystem": "erofs",
      "name": "system_b",
      "size": 4747264
    },
    {
      "filesystem": "erofs",
      "name": "system_dlkm_a",
      "size": 8568832
    },
    {
      "filesystem": "erofs",
      "name": "system_ext_a",
      "size": 258179072
    },
    {
      "filesystem": "erofs",
      "name": "vendor_a",
      "size": 291229696
    },
    {
      "filesystem": "erofs",
      "name": "vendor_dlkm_a",
      "size": 1695744
    }
  ],
  "roles": {
    "genericRamdisk": "init_boot",
    "kernel": "boot",
    "super": "super",
    "userdataTemplate": "userdata",
    "vbmeta": [
      "vbmeta",
      "vbmeta_system",
      "vbmeta_system_dlkm",
      "vbmeta_vendor_dlkm"
    ],
    "vendorBoot": "vendor_boot"
  },
  "schemaVersion": 1,
  "source": {
    "archives": [
      {
        "name": "aosp_cf_arm64_only_phone-img-16373615.zip",
        "sha256": "051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18",
        "size": 1101175103
      }
    ],
    "branch": "aosp-android-latest-release",
    "buildId": "16373615",
    "origin": "ci.android.com",
    "target": "aosp_cf_arm64_only_phone-userdebug"
  }
}
```

Compared with the abbreviated sketch in
[../02-design/android-image.md](../02-design/android-image.md) §3.2, this
example adds the `vbmeta_system`, `vbmeta_system_dlkm`,
`vbmeta_vendor_dlkm`, and `custom` artifacts. It lists all nine non-empty
logical partitions discovered in `super`, including the non-empty `system_b`
slot.

## 6. Fields

### 6.1 Top level

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | `1` | format version (§10) |
| `source` | object (§6.2) | yes | | where the build came from |
| `android` | object (§6.3) | yes | | Android version facts |
| `architecture` | string | yes | `arm64` (§8 M5) | guest CPU architecture |
| `deviceFamily` | string | yes | lowercase words joined by `-`, at most 64 characters | selects the layout `Images/tools/layouts/<deviceFamily>.json`. The layout's own `deviceFamily` must match |
| `artifacts` | array (§6.4) | yes | 1 to 64 items | the files the pipeline uses |
| `roles` | object (§6.5) | yes | | which artifact plays which part in the boot |
| `logicalPartitions` | array (§6.6) | yes | 1 to 64 items | the non-empty logical partitions inside `super` |
| `blankPartitions` | array (§6.7) | yes | 0 to 32 items | partitions created empty (no image in the archive) |
| `androidInfo` | object of string | yes | keys of 1–64 ASCII letters, digits, underscores, dots, or hyphens; values at most 1024 characters | the key/values of `android-info.txt`, copied from the inventory |

Unknown fields are rejected at every level (§10).

### 6.2 `source`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `origin` | string | yes | `ci.android.com` or `apkrun-builder` | prebuilt from Android CI, or built by APKRun's AOSP builder (M5+) |
| `branch` | string | yes | 1 to 128 characters | the CI branch (`aosp-android-latest-release`), or the AOSP branch of the pinned repo manifest |
| `target` | string | yes | `<product>-<variant>` | `aosp_cf_arm64_only_phone-userdebug`, or `apkrun_arm64-trunk_staging-userdebug` / `-user` |
| `buildId` | string | yes | digits (CI), or `ar` + 6 digits (APKRun builder, set through `BUILD_NUMBER`) | the build. It is also the directory name under `Images/manifests/` and the source of the ImageVersion base ([runtime-image-manifest.md](runtime-image-manifest.md) §2) |
| `archives` | array | yes | 1 to 8 items | the downloaded archives |
| `archives[].name` | string | yes | a base name | archive file name |
| `archives[].size` | integer | yes | bytes, at least 1 | archive size |
| `archives[].sha256` | string | yes | 64 lowercase hex | archive hash, equal to `fetch.json` |

The builder's extra provenance (pinned repo manifest, builder container digest, `Guest/` revision) is not in this file. `bundle` writes it into the runtime manifest's `provenance` ([../02-design/android-image.md](../02-design/android-image.md) §11.5).

### 6.3 `android`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `release` | string | yes | digits with optional `.` parts, for example `17` | Android release, from the boot image `os_version` |
| `sdk` | integer | yes | 1 to 10000 | API level, from a table keyed by `release` (17 → 37), cross-checked against `ro.build.version.sdk` in the reference capture |
| `variant` | string | yes | `user`, `userdebug`, or `eng`. Must equal the suffix of `source.target` | build variant |
| `securityPatch` | string | yes | `YYYY-MM` | security patch month, from the boot image `os_version` |

The boot header stores only a year and a month. The day-precise level (`2026-09-05`) comes from `ro.build.version.security_patch` and appears only in the image feed ([runtime-image-manifest.md](runtime-image-manifest.md) §9).

### 6.4 `artifacts[]`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `id` | string | yes | `[a-z][a-z0-9_]*`, at most 36 characters, unique | the name that `roles` refer to |
| `file` | string | yes | a relative `/`-separated path in one archive, no `.` or `..` segment, at most 255 characters | the file. Must be found in exactly one archive |
| `sha256` | string | yes | 64 lowercase hex | equal to the inventory |
| `size` | integer | yes | bytes, at least 1 | equal to the inventory |
| `kind` | string | yes | `bootImage`, `vendorBootImage`, `vbmeta`, `sparse`, `dynamicPartitions`, `filesystem`, or `unknown`. Equal to the inventory | the content kind (§4.4) |
| `partition` | string | yes | `[a-z][a-z0-9_]*`, at most 34 characters, unique across `artifacts` and `blankPartitions` | the partition base name without slot suffix. The layout adds `_a` where the partition is A/B |

- `text` files are not artifacts. Their data goes into `androidInfo`.
- A `kind: unknown` artifact is copied into its partition byte for byte. `inspect` shows why it was not classified.

### 6.5 `roles`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `kernel` | artifact id | yes | kind `bootImage`, `bootKind` `boot`, header v4 | the kernel source (#010) |
| `genericRamdisk` | artifact id | yes | kind `bootImage`, `bootKind` `init_boot`, header v4 | the generic ramdisk (Android 13+ keeps it in `init_boot`) |
| `vendorBoot` | artifact id | yes | kind `vendorBootImage`, header v4 | vendor ramdisks, vendor cmdline, vendor bootconfig |
| `vbmeta` | array of artifact id | yes | 1 to 16 unique ids, each kind `vbmeta`. Item 0 must have partition `vbmeta` and is the top-level image. Every other `kind: vbmeta` artifact must appear in the array, and its partition must be a chain partition of item 0 | input of `androidboot.vbmeta.*` ([../02-design/android-image.md](../02-design/android-image.md) §6.2) |
| `super` | artifact id | yes | kind `dynamicPartitions`, or `sparse` with that content | the super partition |
| `userdataTemplate` | artifact id | no | kind `filesystem`, or `sparse` whose detected content is `filesystem` | used only by userdata fallback A ([../02-design/android-image.md](../02-design/android-image.md) §5.2) |

### 6.6 `logicalPartitions[]`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `name` | string | yes | `[a-z][a-z0-9_]*`, at most 36 characters, unique | liblp partition name, with the slot suffix (`system_a`) |
| `size` | integer | yes | bytes, at least 512, a multiple of 512 | size in the super metadata |
| `filesystem` | string | yes | `ext4`, `erofs`, `f2fs`, or `unknown` | detected type |

Logical partitions of size 0 (the empty `_b` slot) are left out. The list must equal the non-empty partitions of the super metadata (§8 M12).

### 6.7 `blankPartitions[]`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `partition` | string | yes | as `artifacts[].partition`, unique across both lists | partition name |
| `size` | integer | yes | bytes, at least 4096, a multiple of 4096 | size of the zero-filled partition |

The zip ships no image for these partitions. `metadata` is here because the #009 field "metadata" maps to it.

## 7. JSON Schema

This schema is copied byte for byte into `Images/tools/schemas/android-image-manifest.schema.json`. The Python tools validate with it. The Swift `Codable` model in ImageCore must accept exactly the same documents (§12).

The maximum value for `schemaVersion` and byte-size fields is `9223372036854775807`, the largest signed 64-bit integer. ImageCore stores these fields as Swift `Int` on the supported 64-bit platforms.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:android-image-manifest:1",
  "title": "APKRun AndroidImageManifest, schema version 1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "source", "android", "architecture", "deviceFamily", "artifacts", "roles", "logicalPartitions", "blankPartitions", "androidInfo"],
  "properties": {
    "schemaVersion": { "type": "integer", "minimum": 1, "maximum": 9223372036854775807 },
    "source": {
      "type": "object",
      "additionalProperties": false,
      "required": ["origin", "branch", "target", "buildId", "archives"],
      "properties": {
        "origin": { "enum": ["ci.android.com", "apkrun-builder"] },
        "branch": { "type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$(?![\\s\\S])" },
        "target": { "type": "string", "maxLength": 128, "pattern": "^[a-z0-9][a-z0-9_-]*-(user|userdebug|eng)$(?![\\s\\S])" },
        "buildId": { "type": "string", "pattern": "^([0-9]{1,20}|ar[0-9]{6})$(?![\\s\\S])" },
        "archives": {
          "type": "array",
          "minItems": 1,
          "maxItems": 8,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "size", "sha256"],
            "properties": {
              "name": { "type": "string", "pattern": "^[A-Za-z0-9._+-]{1,255}$(?![\\s\\S])" },
              "size": { "type": "integer", "minimum": 1, "maximum": 9223372036854775807 },
              "sha256": { "$ref": "#/$defs/sha256" }
            }
          }
        }
      }
    },
    "android": {
      "type": "object",
      "additionalProperties": false,
      "required": ["release", "sdk", "variant", "securityPatch"],
      "properties": {
        "release": { "type": "string", "pattern": "^[1-9][0-9]*(\\.[0-9]+){0,2}$(?![\\s\\S])" },
        "sdk": { "type": "integer", "minimum": 1, "maximum": 10000 },
        "variant": { "enum": ["user", "userdebug", "eng"] },
        "securityPatch": { "type": "string", "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])$(?![\\s\\S])" }
      }
    },
    "architecture": { "type": "string", "pattern": "^[a-z0-9_]{1,32}$(?![\\s\\S])" },
    "deviceFamily": { "type": "string", "maxLength": 64, "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$(?![\\s\\S])" },
    "artifacts": {
      "type": "array",
      "minItems": 1,
      "maxItems": 64,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "file", "sha256", "size", "kind", "partition"],
        "properties": {
          "id": { "$ref": "#/$defs/artifactId" },
          "file": {
            "type": "string",
            "maxLength": 255,
            "pattern": "^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$(?![\\s\\S])",
            "not": { "pattern": "(^|/)\\.{1,2}(/|$)" }
          },
          "sha256": { "$ref": "#/$defs/sha256" },
          "size": { "type": "integer", "minimum": 1, "maximum": 9223372036854775807 },
          "kind": { "enum": ["bootImage", "vendorBootImage", "vbmeta", "sparse", "dynamicPartitions", "filesystem", "unknown"] },
          "partition": { "$ref": "#/$defs/partition" }
        }
      }
    },
    "roles": {
      "type": "object",
      "additionalProperties": false,
      "required": ["kernel", "genericRamdisk", "vendorBoot", "vbmeta", "super"],
      "properties": {
        "kernel": { "$ref": "#/$defs/artifactId" },
        "genericRamdisk": { "$ref": "#/$defs/artifactId" },
        "vendorBoot": { "$ref": "#/$defs/artifactId" },
        "vbmeta": { "type": "array", "minItems": 1, "maxItems": 16, "uniqueItems": true, "items": { "$ref": "#/$defs/artifactId" } },
        "super": { "$ref": "#/$defs/artifactId" },
        "userdataTemplate": { "$ref": "#/$defs/artifactId" }
      }
    },
    "logicalPartitions": {
      "type": "array",
      "minItems": 1,
      "maxItems": 64,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "size", "filesystem"],
        "properties": {
          "name": { "type": "string", "pattern": "^[a-z][a-z0-9_]{0,35}$(?![\\s\\S])" },
          "size": { "type": "integer", "minimum": 512, "maximum": 9223372036854775807, "multipleOf": 512 },
          "filesystem": { "enum": ["ext4", "erofs", "f2fs", "unknown"] }
        }
      }
    },
    "blankPartitions": {
      "type": "array",
      "maxItems": 32,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["partition", "size"],
        "properties": {
          "partition": { "$ref": "#/$defs/partition" },
          "size": { "type": "integer", "minimum": 4096, "maximum": 9223372036854775807, "multipleOf": 4096 }
        }
      }
    },
    "androidInfo": {
      "type": "object",
      "propertyNames": { "pattern": "^[A-Za-z0-9_.-]{1,64}$(?![\\s\\S])" },
      "additionalProperties": { "type": "string", "maxLength": 1024 }
    }
  },
  "$defs": {
    "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$(?![\\s\\S])" },
    "artifactId": { "type": "string", "pattern": "^[a-z][a-z0-9_]{0,35}$(?![\\s\\S])" },
    "partition": { "type": "string", "pattern": "^[a-z][a-z0-9_]{0,33}$(?![\\s\\S])" }
  }
}
```

## 8. Validation rules

Order: M1 first (so a newer file gets a useful message and not a list of unknown fields), then the schema (§7), then M2–M15. `manifest --check` reports every failure. The other commands stop at the first one. M1–M3, M5, M7–M9, and M14–M15 need only the manifest. M4, M6, and M10–M13 read the files. `--no-files` skips them.

Every anchored string pattern in the schema includes an end-of-input
assertion. A plain `$` can match before a final line terminator, so the
patterns also assert that no character follows. Swift validation additionally
requires each regular-expression match to cover the complete input string.

The messages of M1–M7 are fixed by [../02-design/android-image.md](../02-design/android-image.md) §3.3. M8–M13 follow the same style. Each message is shown with example values.

| # | Check | Message |
|---|---|---|
| M1 | `schemaVersion` known | `android-image.json: schemaVersion 3 is newer than this tool supports (1). Update Images/tools.` |
| M2 | every role points to an existing artifact `id` | `roles.vendorBoot = "vendor_boot2": no artifact with that id. Known ids: boot, init_boot, …` |
| M3 | artifact kind matches the role (§6.5) | `artifacts[2] (role vendorBoot): expected kind vendorBootImage v4, found bootImage v4. Is the file swapped?` |
| M4 | the file exists, and size and SHA-256 match | `super.img: SHA-256 mismatch (expected …, got …). Re-run fetch or re-inventory.` |
| M5 | `architecture` is `arm64` | `architecture x86_64 is not supported. Use an arm64 target.` |
| M6 | boot and init_boot are header v4 and match the `boot` and `init_boot` role kinds; vendor_boot is header v4 | `vendor_boot.img header v3 is not supported (needs v4 ramdisk table).` |
| M7 | no duplicate partition names across `artifacts` and `blankPartitions` | `partition "misc" appears in artifacts[7] and blankPartitions[0].` |
| M8 | artifact ids are unique | `artifact id "vbmeta" appears in artifacts[3] and artifacts[4].` |
| M9 | `android.variant` equals the suffix of `source.target` | `android.variant "user" does not match target aosp_cf_arm64_only_phone-userdebug.` |
| M10 | each `file` is in exactly one archive, and its inventory entry has the same size, hash, and kind; the recorded inventory is archive-backed, its archive name, size, and hash match `source.archives`, and its branch, build ID, and target match the fetched archive metadata in a valid `fetch.json` | `artifacts[8] (cuttlefish_example_custom.img): kind filesystem does not match the inventory (unknown). Re-run the inventory.` |
| M11 | every source inventory vbmeta file is a `kind: vbmeta` artifact listed in `roles.vbmeta`; chain items follow item 0's descriptor order | `roles.vbmeta[2] = "vbmeta_system_dlkm": vbmeta.img has no chain descriptor for partition vbmeta_system_dlkm.` |
| M12 | `logicalPartitions` equals the non-empty partitions in the super metadata (name, size, filesystem) | `logicalPartitions: system_dlkm_a is in super.img but not in the manifest.` |
| M13 | `android.release` and `securityPatch` equal the `roles.kernel` boot header `os_version`, and `sdk` equals the table entry for `release` | `android.release "16" does not match boot.img os_version 17.0.0.` |
| M14 | `source.buildId` format matches `source.origin`: numeric for `ci.android.com`, or `ar` plus six digits for `apkrun-builder` | `source.buildId "16373615" does not match origin apkrun-builder. Use an ar-prefixed six-digit build ID.` |
| M15 | logical partition names are unique | `logicalPartitions[1].name "system_a" duplicates logicalPartitions[0].name. Use a unique logical partition name.` |

- A message always names the file or field, what was expected, what was found, and the fix.
- For M10, a recorded inventory with `source.type` other than `zip` fails because it cannot establish the archive fingerprint declared by the manifest. The actual archive must also have matching `fetch.json` metadata with branch, build ID, and target; missing provenance fails closed. Those values are checked directly against the archive record, so editing both `inventory.json` and the manifest cannot override them. Use `fetch` without an API key to record a manual download before inventorying it.
- The layout check is part of `disks` and `bundle`: `layout cuttlefish-tablet-arm64 does not match deviceFamily cuttlefish-phone-arm64.` Every partition the layout names must be an artifact `partition` or a `blankPartitions` entry: `layout partition "custom" has no artifact or blank partition.`

## 9. Consumers

| Consumer | Uses | Output |
|---|---|---|
| `extract` (#010) | `roles.kernel`, `roles.genericRamdisk`, `roles.vendorBoot` | `Images/work/<buildId>/boot/`: `kernel` (decompressed, `ARM\x64` at 0x38), `ramdisk.img` (vendor fragments in table order without `RECOVERY`, then `init_boot`), `vendor-bootconfig.txt`, `cmdline.txt`, `dtb`, `extraction.json` |
| `disks` (#011) | `artifacts[].partition`, `roles.super` (unsparsed into `os.img`), `blankPartitions`, `roles.userdataTemplate` (fallback A only), and the layout | `os.img`, `persistent.img`, `userdata.img`, `disks.json` |
| bootconfig baseline (#012/#013) | top-level vbmeta chain descriptors in order, with raw vbmeta artifacts checked against `roles.vbmeta` and footer-backed images resolved from their manifest artifacts | `androidboot.vbmeta.{digest,hash_alg,size,avb_version,invalidate_on_error}` |
| `bundle` (#065) | `source`, `android` | the runtime manifest `provenance` ([runtime-image-manifest.md](runtime-image-manifest.md) §4). The ImageVersion base is `cf` + `buildId` for `ci.android.com`, or `buildId` itself for `apkrun-builder` |
| ImageCore `AndroidImageManifest` (Swift `Codable`) | `source`, `android` inside `provenance` | diagnostics and `apkrun image list`. ImageCore never reads `android-image.json` from the source tree at run time |

The layout file never names a file. It names partitions, and this manifest maps partitions to files. That keeps the "no hard-coded file names" rule (§1).

## 10. Versioning rules

- `AndroidImageManifest.schemaVersion` is an integer. Only `1` is defined.
- A reader refuses a newer version with M1. `Images/tools` reads only the current version. A change that raises the version also rewrites every committed manifest, in the same change.
- Unknown fields are rejected. This file is ours and reviewed by a human, so a typo must fail. (The Direct provider manifest does the opposite, because third parties write it: [direct-provider-manifest.md](direct-provider-manifest.md) §9.) ImageCore converts JSON decoding errors to typed manifest failures without including decoder debug descriptions or raw values. It escapes control, quoting, and bidirectional-formatting characters in input-derived paths and values, and limits each displayed value to 128 Unicode scalars.
- Any change to the schema, even an optional field, raises `schemaVersion`. The schema `$id` carries the version.
- `inventory.json` has its own `schemaVersion` with the same rules. Version `2` is current; it adds the bounded AVB footer `vbmetaSize` and `version` fields, plus checked `fetch.json` build provenance in `source`. Inventory files are regenerated, never migrated.

## 11. Writers and readers

| Role | Component | Notes |
|---|---|---|
| Writer | `scripts/inventory-cuttlefish.py` (`apkrun_image.inventory`) | `inventory.json`. Never edited by hand |
| Writer | `python3 -m apkrun_image manifest` | a draft `android-image.json` |
| Writer | a maintainer | reviews the draft, then commits it. Edits must keep §8 passing |
| Reader | `manifest --check`, `extract`, `disks`, `bundle` (Python) | validate with §7 and §8 first |
| Reader | ImageCore (Swift `Codable`) | the `provenance` copy only |
| Reader | CI | runs `manifest --check` on every committed manifest, and the fixtures of §12 |

## 12. Tests and fixtures

| Tier | Test | Task |
|---|---|---|
| T0 | the inventory of the fixture zip is byte-identical on a second run | #008 |
| T0 | kind detection for every row of §4.4, including a `boot.img` that is really a vendor boot image (`nameMismatch: true`) | #008 |
| T0 | every file in `Images/tools/tests/fixtures/manifests/invalid/` fails with its expected message in Python, and in Swift except the image-file checks listed in `invalid/python-only.txt`; malformed JSON field types become typed manifest errors, and input-derived field paths and diagnostic values are escaped and bounded | #009 |
| T0 | the Swift `Codable` model accepts every valid fixture and every committed manifest | #009 |
| T1 | `manifest --check` passes on the committed `16373615` manifest with the real archive | #009 |

Each invalid fixture is a pair: `<name>.json` and `<name>.expected.txt` (the exact message). Files that need image content (M4, M6, M10–M13) use small synthetic images in `Images/tools/tests/fixtures/images/`.
