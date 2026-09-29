# Runtime Image Bundle, Manifest, and Image Feed

| Field | Value |
|---|---|
| Status | Baseline |
| Related | [android-image-manifest.md](android-image-manifest.md), [error-catalog.md](error-catalog.md) (domains `image`, `maintenance`), [configuration.md](configuration.md), [../02-design/package-store.md](../02-design/package-store.md) §4.6, [../01-architecture/security-model.md](../01-architecture/security-model.md) §7, [../05-development/build-system.md](../05-development/build-system.md) §10, FR-IMG-* |

This document defines the formats that carry an Android system to a Mac:

- the **image version** string (§2);
- the **runtime image bundle**, the directory `Images/<imageVersion>/` (§3);
- its **manifest**, `manifest.json` (the `RuntimeImageManifest`, §4 and §5);
- its **signature** `manifest.sig` and the `SHA256SUMS` file (§6);
- the **release archive** `<imageVersion>.aar` (§8);
- the **image feed** `feed.json` and `feed.json.sig` (§9).

The design lives in [../02-design/android-image.md](../02-design/android-image.md) (the bundle, ImageCore) and [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) (updates). This document fixes field names, types, limits, and encodings. When it disagrees with those design documents on behavior, the design documents win and this document has a bug.

---

## 1. Overview

- A build-time pipeline (`python3 -m apkrun_image bundle`, #065) turns one Android build into one bundle. The Mac never parses AOSP outputs ([ADR-0011](../01-architecture/decisions/0011-runtime-image-bundle.md)).
- ImageCore (in apkrund) verifies, installs, and consumes bundles. It never changes a file inside an installed bundle.
- The manifest is the only index of the bundle. No Swift code names a partition, a disk file, or a console port. They come from the manifest ([../02-design/android-image.md](../02-design/android-image.md) §4.2, §7.1).
- The manifest is signed. Its `files` block pins the size and SHA-256 of every other file. So the signature covers the whole bundle.
- Release bundles reach users as an `.aar` archive listed in a signed feed. Development bundles are installed as directories.

## 2. ImageVersion

### 2.1 Format

```text
YYYY.MM.N-<base>-<arch>
2026.10.0-cf16373615-arm64      stock image from ci.android.com build 16373615
2026.10.0-ar000123-arm64        APKRun product image from builder build ar000123
```

| Part | Rule | Meaning |
|---|---|---|
| `YYYY` | 4 digits | release year |
| `MM` | 2 digits, `01` to `12` | release month |
| `N` | `0` to `999`, no leading zeros | sequence within the month |
| `base` | `cf` + the CI build ID (1 to 20 digits) when `provenance.source.origin` is `ci.android.com`. The builder build ID itself (`ar` + 6 digits) when it is `apkrun-builder` | the Android build. Informational only |
| `arch` | `arm64` | guest architecture. v1 has no other value |

Full regular expression:

```text
^([0-9]{4})\.(0[1-9]|1[0-2])\.(0|[1-9][0-9]{0,2})-(cf[0-9]{1,20}|ar[0-9]{6})-(arm64)$
```

The **short form** `YYYY.MM.N` (regular expression `^[0-9]{4}\.(0[1-9]|1[0-2])\.(0|[1-9][0-9]{0,2})$`) appears in exactly these places:

- `compatibility.upgradeFrom.minimumImageVersion` (§4.9) and the feed's `upgradeFrom.minimumImageVersion` (§9);
- the `--image-version` input of `bundle`, which appends `-<base>-<arch>` itself ([../02-design/android-image.md](../02-design/android-image.md) §10.2);
- user-facing text ("Go back to Android 2026.07.0?", [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.8) and release note URLs.

### 2.2 Parsing

- The Swift type is `ImageVersion {year, month, sequence, base, architecture}`. It is `Codable` as a single string, `Comparable`, and `CustomStringConvertible` ([../02-design/android-image.md](../02-design/android-image.md) §9.1).
- Parsing uses the regular expression of §2.1 on the whole string. A failure in a manifest gives `ImageFailure.manifestInvalid(path, reason)`. A failure in the feed gives `MaintenanceFailure.imageFeedInvalid(detail)`.
- Rendering is canonical. `description` of a parsed value returns the exact input string, and parsing a rendered value returns an equal value. Leading zeros in `N` are rejected so that this holds.
- The short form has its own parser. It yields `(year, month, sequence)` only.

### 2.3 Ordering

- Versions are compared on `(year, month, sequence)` as integers, in that order. `base` and `architecture` do not take part ([../02-design/android-image.md](../02-design/android-image.md) §12.1).
- `==` compares all five fields. So two versions can be neither `<` nor `>` and still differ. That happens when the same triple is published with two bases. It is a publishing error. A reader treats such a candidate as **not newer** (C1 fails), and a feed that lists two entries with the same triple is invalid (§9.4).
- A short form compares with a full version on the triple only.
- Versions are monotonic. APKRun never installs or activates a lower version automatically (`ImageFailure.downgradeRejected(from, to)`). The only ways back are the `previous` image and a recovery point ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.8).

### 2.4 Where the version appears

| Place | Form |
|---|---|
| bundle directory `Images/<imageVersion>/`, the `current` and `previous` symlink targets | full |
| `manifest.json` `imageVersion` | full |
| `Runtime/instance/instance.json` (image in use) | full |
| recovery points `Runtime/instance/recovery-points/<timestamp>-<imageVersion>/`, with `<timestamp>` = UTC `YYYYMMDDTHHMMSSZ` | full |
| bootconfig `androidboot.apkrun.image` (layer 4, [../02-design/android-image.md](../02-design/android-image.md) §6.2) | full |
| release archive `<imageVersion>.aar` and `Cache/images/<imageVersion>.aar.partial` | full |
| feed entry `imageVersion` (§9), `Images/update-state.json` | full |
| `apkrun image list`, diagnostics, `image.current` | full, with the short form as the display name |

## 3. Bundle layout

### 3.1 Files

The layout is fixed by [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §1. The paths below are the v1 values. ImageCore takes every path from the manifest, never from this table.

```text
Images/<imageVersion>/
├── manifest.json            # §4, §5
├── manifest.sig             # §6.1
├── SHA256SUMS               # §6.2
├── boot/
│   ├── kernel               # uncompressed arm64 Image
│   ├── ramdisk.img          # vendor ramdisk fragments + generic ramdisk, no bootconfig trailer
│   ├── bootconfig.txt       # bootconfig layers 1 and 2 (§3.2)
│   └── cmdline.txt          # kernel command line (§3.3)
├── disks/
│   └── os.img               # read-only raw GPT disk: boot and vbmeta partitions, unsparsed super
├── templates/
│   ├── persistent.img       # raw GPT template: misc, metadata, frp (blank)
│   └── userdata.img         # raw GPT template: userdata (§4.5)
└── legal/
    └── notice.html          # notices and source offers; release bundles only (§4.2)
```

- The bundle contains exactly these files: the three metadata files plus every path in `files` (§4.10). Anything else is `ImageFailure.unexpectedFile(file)`.
- Nothing inside `Images/<imageVersion>/` changes after installation. The only exception is hole punching during the install itself (§8.3), which does not change any byte.
- Neighbours, which are not part of a bundle:

| Path | Written by | Format |
|---|---|---|
| `Images/current`, `Images/previous` | ImageCore (`setCurrent`) | symlinks to a bundle directory name |
| `Images/.installing-<name>/` | ImageCore during an install (§8.3) | a partial bundle. Deleted at startup when orphaned |
| `Images/update-state.json` | `ImageUpdateCoordinator` only | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3 |
| `Runtime/instance/instance.json` | ImageCore (`InstanceStore`) | [../02-design/android-image.md](../02-design/android-image.md) §5.1 |
| `Runtime/instance/boot/initrd.img` | ImageCore before every boot | `ramdisk.img` plus the merged bootconfig trailer ([../02-design/android-image.md](../02-design/android-image.md) §6.3) |
| `Runtime/instance/persistent.img`, `userdata.img` | ImageCore at provisioning | APFS clones of the templates. The instance file name is the template's file name |

### 3.2 `boot/bootconfig.txt`

The file holds bootconfig layer 1 (vendor) and the fixed part of layer 2 (image). The GPU profile part of layer 2 is in the manifest (§4.7). Layers 3 and 4 are computed at boot ([../02-design/android-image.md](../02-design/android-image.md) §6.1).

```text
[vendor]
androidboot.hardware = "cutf_cvm"
kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size = "16384"
[image]
androidboot.force_normal_boot = "1"
androidboot.hypervisor.vm.supported = "0"
androidboot.slot_suffix = "_a"
androidboot.vbmeta.device_state = "unlocked"
androidboot.verifiedbootstate = "orange"
```

(Excerpt. The real file also has the vbmeta digest keys, the fstab suffix, the HAL and APEX selection, and the other keys of [../02-design/android-image.md](../02-design/android-image.md) §6.2.)

Rules:

- ASCII, LF line ends, a final LF. No blank lines and no comments.
- The section header `[vendor]` comes first and `[image]` second. Each appears exactly once. Either section may be empty.
- Every other line is `<key> = "<value>"` with one space on each side of `=`.
- Keys match `[A-Za-z0-9_.-]+`, at most 256 characters. Values are printable ASCII without `"`, backslash, or newline, at most 1024 characters ([../02-design/android-image.md](../02-design/android-image.md) §6.1).
- Keys are sorted by byte value within a section. A key appears at most once in the whole file, unless `boot.bootconfigOverrides` (§4.4) lists it. Then it may appear in both sections, and the `[image]` value wins.
- The build fails if the serialized layers 1 and 2 (with the largest GPU profile) exceed 16 KiB. ImageCore fails the boot above 32 KiB with `bootconfigTooLarge(size)`.
- A file that does not parse gives `manifestInvalid(path: "boot/bootconfig.txt", reason)` during boot preparation.

### 3.3 `boot/cmdline.txt`

- The exact kernel command line: ASCII, one line, tokens separated by single spaces, **no** trailing newline.
- Content: the vendor cmdline, the boot cmdline, then the APKRun additions starting with `console=hvc0` ([../02-design/android-image.md](../02-design/android-image.md) §6.4). It must contain the token `bootconfig`.
- No token starts with `androidboot.`. The length is at most 2048 bytes (`cmdlineTooLong(length)` at boot, and a build failure before that).
- Example (157 bytes, the stock build 16373615):

```text
printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig console=hvc0
```

## 4. `manifest.json`

### 4.1 Complete example

The development bundle of the stock build 16373615. The `source` and `android` blocks are copied from [android-image-manifest.md](android-image-manifest.md) §5. Sizes of the boot files and all hashes are illustrative. The partition layout is computed with the rules of §4.5.

The file on disk has its keys sorted (§4.11). This example shows them in reading order.

```json
{
  "schemaVersion": 1,
  "imageVersion": "2026.10.0-cf16373615-arm64",
  "kind": "stock",
  "provenance": {
    "source": {
      "origin": "ci.android.com",
      "branch": "aosp-android-latest-release",
      "target": "aosp_cf_arm64_only_phone-userdebug",
      "buildId": "16373615",
      "archives": [
        {
          "name": "aosp_cf_arm64_only_phone-img-16373615.zip",
          "size": 1476395008,
          "sha256": "4a70fe9aa6436e02c2dea340fbd1e352e4ef2d8ce6ca52ad25d4b95471fc8bf2"
        }
      ]
    },
    "android": { "release": "17", "sdk": 37, "variant": "userdebug", "securityPatch": "2026-09" },
    "deviceFamily": "cuttlefish-phone-arm64",
    "layout": {
      "path": "Images/tools/layouts/cuttlefish-phone-arm64.json",
      "sha256": "1dc5ae5b68174891b6aa9850aa05ee0d9ae8a20468d9517259951a2dd9e9c0f0"
    },
    "reference": "Images/reference/16373615/target",
    "tools": {
      "apkrunImage": "1.0.0",
      "mkbootimg": "fb725eb84f5db137341aee2a02ee57c0b9fcafed",
      "avbtool": "27dc57bfbba59baa6be09238d4c498a47fbd427f"
    },
    "revisions": { "imagesTools": "6877b3530a63a713f95c28e652995592dfba95e1", "guest": null },
    "pinnedManifestSHA256": null,
    "builderImageDigest": null
  },
  "guest": { "sdk": 37, "abis": ["arm64-v8a"], "targetSdkFloor": 24 },
  "boot": {
    "kernel": { "path": "boot/kernel", "size": 43581440, "sha256": "6923dd1bc0460082c5d55a831908c24a282860b7f1cd6c2b79cf1bc8857c639c" },
    "ramdisk": { "path": "boot/ramdisk.img", "size": 23068672, "sha256": "b522bcfff2ba6df0999d4772142b22165fff473d596d40915275f324f5c2322b" },
    "bootconfig": { "path": "boot/bootconfig.txt", "size": 1843, "sha256": "e158851fbebb402e1f18ea9372ea2f76b4dea23eceb5c4b92e5b27ade8537f5b" },
    "cmdline": { "path": "boot/cmdline.txt", "size": 157, "sha256": "5f09fae74bfa7f97e26986705f4d193c67a8f6484fb3c6c4dfc40d011b9e0705" },
    "kernelPageSize": 4096,
    "bootconfigOverrides": []
  },
  "disks": [
    {
      "role": "os",
      "path": "disks/os.img",
      "readOnly": true,
      "identifier": "apkrun-os",
      "logicalSize": 7669284864,
      "partitions": [
        { "label": "boot_a", "firstLBA": 2048, "size": 67108864, "sha256": "4509beb0ab401d71fa4a5cd94a55c9a74f13332776ae4019c5bfc4c2005157ff" },
        { "label": "init_boot_a", "firstLBA": 133120, "size": 8388608, "sha256": "cd19026f4b3933f79100922d0383d948b53744aca39b50b44b7e81c021cde3d7" },
        { "label": "vendor_boot_a", "firstLBA": 149504, "size": 67108864, "sha256": "fce16cbfd9d47eeeb76c893c5bf880dd01cae03cba8e9af0845e4646592aa9f4" },
        { "label": "vbmeta_a", "firstLBA": 280576, "size": 65536, "sha256": "a0c6f07a4b3a17fb9348db981de3c5602e2685d626599be1bd909195c694a57b" },
        { "label": "vbmeta_system_a", "firstLBA": 282624, "size": 65536, "sha256": "0ed258163a6ded2b600f003e91e541e90380e52eb1cdac2444d9df1b1daf9996" },
        { "label": "vbmeta_system_dlkm_a", "firstLBA": 284672, "size": 65536, "sha256": "9754204bb12c6d45da311778c739179c0154ec3fa8f4155d4a51223064e405df" },
        { "label": "vbmeta_vendor_dlkm_a", "firstLBA": 286720, "size": 65536, "sha256": "560fcdda0d381e5db9c99bb5d872972e4fd70c0e8f4ae7226975823373c74604" },
        { "label": "super", "firstLBA": 288768, "size": 7516192768, "sha256": "ee505954c0143f13dcb1082a57f545499b9ed0154cc2884fd62ce037b9d346b0" },
        { "label": "custom", "firstLBA": 14968832, "size": 4194304, "sha256": "6cdfd271da635d491e37a2b4a1044b306e6e9e039aeadee95bb355efadf8cb33" }
      ]
    }
  ],
  "templates": [
    {
      "role": "persistent",
      "path": "templates/persistent.img",
      "readOnly": false,
      "identifier": "apkrun-persist",
      "logicalSize": 71303168,
      "partitions": [
        { "label": "misc", "firstLBA": 2048, "size": 1048576, "sha256": "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58" },
        { "label": "metadata", "firstLBA": 4096, "size": 67108864, "sha256": "3b6a07d0d404fab4e23b6d34bc6696a6a312dd92821332385e5af7c01c421351" },
        { "label": "frp", "firstLBA": 135168, "size": 1048576, "sha256": "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58" }
      ]
    },
    {
      "role": "userdata",
      "path": "templates/userdata.img",
      "readOnly": false,
      "identifier": "apkrun-data",
      "logicalSize": 16777216,
      "userdataStrategy": "blankFormattable",
      "partitions": [
        { "label": "userdata", "firstLBA": 2048, "size": 14680064, "sha256": "e86bae8c0598c4ff83c695f467daa4a1e8fa01d57f9140372993366204022a4d" }
      ]
    }
  ],
  "consolePorts": [
    { "index": 0, "role": "systemConsole", "name": "console" },
    { "index": 1, "role": "silent", "name": "serial" },
    { "index": 2, "role": "silent", "name": "logcat" },
    { "index": 3, "role": "silent", "name": "keymaster" },
    { "index": 4, "role": "silent", "name": "gatekeeper" },
    { "index": 5, "role": "silent", "name": "bluetooth" },
    { "index": 6, "role": "silent", "name": "gnss" },
    { "index": 7, "role": "silent", "name": "location" },
    { "index": 8, "role": "silent", "name": "confirmationui" },
    { "index": 9, "role": "silent", "name": "uwb" },
    { "index": 10, "role": "silent", "name": "oemlock" },
    { "index": 11, "role": "silent", "name": "keymint" },
    { "index": 12, "role": "silent", "name": "nfc" },
    { "index": 13, "role": "silent", "name": "weaver" },
    { "index": 14, "role": "silent", "name": "mcu_control" },
    { "index": 15, "role": "silent", "name": "mcu_uart" },
    { "index": 16, "role": "silent", "name": "ti50_tpm" },
    { "index": 17, "role": "silent", "name": "jcardsim" },
    { "index": 18, "role": "silent", "name": "sensors_control" },
    { "index": 19, "role": "silent", "name": "sensors_data" }
  ],
  "gpuProfiles": {
    "drmVirgl": {
      "bootconfig": {
        "androidboot.cpuvulkan.version": "0",
        "androidboot.hardware.egl": "mesa",
        "androidboot.hardware.gralloc": "minigbm",
        "androidboot.hardware.hwcomposer": "ranchu",
        "androidboot.hardware.hwcomposer.display_finder_mode": "drm",
        "androidboot.hardware.hwcomposer.mode": "client",
        "androidboot.opengles.version": "196608"
      },
      "overrides": [],
      "requiredHostCapabilities": ["virgl", "edid"]
    },
    "guestSwiftshader": {
      "bootconfig": {
        "androidboot.cpuvulkan.version": "4202496",
        "androidboot.hardware.egl": "angle",
        "androidboot.hardware.gralloc": "minigbm",
        "androidboot.hardware.hwcomposer": "ranchu",
        "androidboot.hardware.hwcomposer.display_finder_mode": "drm",
        "androidboot.hardware.hwcomposer.mode": "client",
        "androidboot.hardware.vulkan": "pastel",
        "androidboot.opengles.version": "196609"
      },
      "overrides": [],
      "requiredHostCapabilities": ["edid"]
    }
  },
  "requirements": {
    "minimumRuntimeVersion": "1.0.0",
    "guestProtocol": { "min": 1, "max": 1 },
    "agents": []
  },
  "userdata": { "schemaVersion": 1, "upgradableFrom": [1] },
  "compatibility": { "upgradeFrom": { "minimumImageVersion": "2026.10.0" } },
  "files": [
    { "path": "boot/bootconfig.txt", "size": 1843, "sha256": "e158851fbebb402e1f18ea9372ea2f76b4dea23eceb5c4b92e5b27ade8537f5b" },
    { "path": "boot/cmdline.txt", "size": 157, "sha256": "5f09fae74bfa7f97e26986705f4d193c67a8f6484fb3c6c4dfc40d011b9e0705" },
    { "path": "boot/kernel", "size": 43581440, "sha256": "6923dd1bc0460082c5d55a831908c24a282860b7f1cd6c2b79cf1bc8857c639c" },
    { "path": "boot/ramdisk.img", "size": 23068672, "sha256": "b522bcfff2ba6df0999d4772142b22165fff473d596d40915275f324f5c2322b" },
    { "path": "disks/os.img", "size": 7669284864, "sha256": "840a8dcfeae95966a870b0b5257997ce94cbc19dd979409d1671d2e93a9e0de6" },
    { "path": "templates/persistent.img", "size": 71303168, "sha256": "1c61425b1ba94748e725edd6fbc902b80e08483116a8affb4b8829143e486f1e" },
    { "path": "templates/userdata.img", "size": 16777216, "sha256": "374298ce07e00296d99b3db8860b6ec7002c54d1b83796799a2686fd5bb0851b" }
  ]
}
```

A product image (`kind: apkrun`, M5+) differs in these blocks. The fragment below is not a complete manifest:

```json
{
  "imageVersion": "2026.10.0-ar000123-arm64",
  "kind": "apkrun",
  "provenance": {
    "revisions": { "imagesTools": "6877b3530a63a713f95c28e652995592dfba95e1", "guest": "f3058939c7f1eee9ed6eff33515ce8859dcfe942" },
    "pinnedManifestSHA256": "22f569708cad2f7228fa6fbc11a3f017a3d08f46627c7d1b9f122c81337d6102",
    "builderImageDigest": "sha256:030da9febeafff405e9794f34db3a6ac1dd1e5bccb5be732891b2fb6b5f8af14"
  },
  "requirements": {
    "minimumRuntimeVersion": "1.1.0",
    "guestProtocol": { "min": 1, "max": 1 },
    "agents": [
      { "package": "io.apkrun.guest", "versionCode": 12 },
      { "package": "io.apkrun.store", "versionCode": 12 }
    ]
  }
}
```

### 4.2 Top level

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | `1` | format version of the manifest (§11) |
| `imageVersion` | string | yes | full form (§2.1). Base consistent with `provenance.source` (S1) | the version of this bundle. Equals the bundle directory name |
| `kind` | string | yes | `stock` or `apkrun`. `stock` exactly when `provenance.source.origin` is `ci.android.com` (S2) | `stock` = a ci.android.com build, development only. `apkrun` = the APKRun product image |
| `provenance` | object | yes | §4.3 | where the bundle came from |
| `guest` | object | yes | §4.3 | guest facts for package checks before the first boot |
| `boot` | object | yes | §4.4 | direct-boot files |
| `disks` | array | yes | exactly one entry, role `os` (§4.5) | read-only disks, attached first |
| `templates` | array | yes | exactly two entries, roles `persistent` then `userdata` (§4.5) | templates of the per-instance disks |
| `consolePorts` | array | yes | 1 to 32 entries (§4.6). v1 layouts have 20 | the console port plan |
| `gpuProfiles` | object | yes | §4.7 | GPU profile bootconfig fragments |
| `requirements` | object | yes | §4.8 | what the host must provide |
| `userdata` | object | yes | §4.9 | userdata schema compatibility |
| `compatibility` | object | yes | §4.9 | which images may migrate to this one |
| `legal` | object | no | `{notice}`: one file entry with `path` under `legal/`. Required in bundles published on a feed; the release pipeline checks it (#093) | the image's license notices and source offers ([../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md) §7.3). ImageCore verifies the file like every other file and never reads it |
| `files` | array | yes | 1 to 64 entries (§4.10) | every file of the bundle except the three metadata files |

Unknown fields are rejected at every level (§11).

### 4.3 `provenance` and `guest`

`provenance` is informational. ImageCore shows it (`apkrun image list`, diagnostics) but makes no decision from it, except S1, S2, and S14.

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `source` | object | yes | exactly the `source` block of the AndroidImageManifest, same schema ([android-image-manifest.md](android-image-manifest.md) §6.2) | the Android build and its downloaded archives |
| `android` | object | yes | exactly the `android` block of the AndroidImageManifest ([android-image-manifest.md](android-image-manifest.md) §6.3) | release, SDK, variant, security patch month |
| `deviceFamily` | string | yes | as in the AndroidImageManifest | the device family, for example `cuttlefish-phone-arm64` |
| `layout` | object | yes | `{path, sha256}`. `path` relative to the repository root | the layout file used, and its SHA-256 |
| `reference` | string or null | yes | a repository-relative path, or null | the reference capture that supplied bootconfig values ([../02-design/android-image.md](../02-design/android-image.md) §8) |
| `tools` | object | yes | `apkrunImage`: `MAJOR.MINOR.PATCH`. `mkbootimg`, `avbtool`: 40 hex digits | tool versions: the `apkrun_image` package, and the pinned revisions of the vendored AOSP tools (`ThirdParty.lock.json`) |
| `revisions.imagesTools` | string | yes | 40 lowercase hex digits, optionally followed by `-dirty` | git revision of `Images/tools` |
| `revisions.guest` | string or null | yes | same pattern. Null for `stock` | git revision of `Guest/` |
| `pinnedManifestSHA256` | string or null | yes | 64 lowercase hex. Null for `stock`, required for `apkrun` | SHA-256 of `Guest/product/manifest/pinned.xml` ([../02-design/android-image.md](../02-design/android-image.md) §11.5) |
| `builderImageDigest` | string or null | yes | `sha256:` + 64 lowercase hex. Null for `stock`, required for `apkrun` | digest of the builder container image |

The bundle has no timestamps. That keeps it deterministic ([../02-design/android-image.md](../02-design/android-image.md) §10.2).

`guest` gives APKStoreCore its `GuestFacts` before the first boot. After the first Guest Agent `Hello`, `instance.json` has the live values ([../02-design/package-store.md](../02-design/package-store.md) §4.6).

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `guest.sdk` | integer | yes | 1 to 10000. Equals `provenance.android.sdk` (S14) | guest API level (I8) |
| `guest.abis` | array of string | yes | 1 to 8 unique items, each `[a-z0-9_-]{1,32}`. Contains `arm64-v8a` | guest ABIs, primary first (I7) |
| `guest.targetSdkFloor` | integer | yes | 1 to 10000. 23 for SDK 34, 24 for SDK 35 and later | the lowest target SDK Android installs (I9) |

### 4.4 `boot`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `kernel` | file entry | yes | `path` under `boot/` | uncompressed arm64 `Image` (`ARM\x64` at offset 0x38) |
| `ramdisk` | file entry | yes | `path` under `boot/` | the initrd without a bootconfig trailer |
| `bootconfig` | file entry | yes | `path` under `boot/`. Format §3.2 | bootconfig layers 1 and 2 |
| `cmdline` | file entry | yes | `path` under `boot/`. Format §3.3 | kernel command line |
| `kernelPageSize` | integer | yes | `4096`, `16384`, or `65536` | page size from the arm64 `Image` header flags (bits 1–2). Checked by `bundle`, shown in diagnostics |
| `bootconfigOverrides` | array of string | yes | 0 to 64 unique bootconfig keys | layer 1 keys that the `[image]` section may override ([../02-design/android-image.md](../02-design/android-image.md) §6.1) |

A **file entry** is `{path, size, sha256}`: a bundle-relative path, the size in bytes, and the SHA-256 in lowercase hex. It must equal the `files` entry with the same path (S3).

### 4.5 `disks` and `templates`

Each entry describes one raw GPT disk image with 512-byte sectors ([../02-design/android-image.md](../02-design/android-image.md) §4.2, §4.4).

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `role` | string | yes | `os` in `disks`. `persistent`, then `userdata`, in `templates` | what the disk is for |
| `path` | string | yes | under `disks/` for `os`, under `templates/` for templates | the bundle file |
| `readOnly` | boolean | yes | `true` for `os`, `false` for templates | how VZ attaches the disk (or its instance clone) |
| `identifier` | string | yes | `[a-z0-9][a-z0-9-]{0,19}` (the virtio-blk serial limit is 20 bytes). Unique | `blockDeviceIdentifier`. For logs and host lookups only |
| `logicalSize` | integer | yes | a multiple of 1 MiB, at least 2 MiB. Equals the file size in `files` | the disk size in bytes. For `userdata`, the template size before growth |
| `userdataStrategy` | string | only for `userdata` | `blankFormattable` or `prebuiltTemplate`. Forbidden for other roles | `blankFormattable`: an empty partition that Android formats on first boot, grown at provisioning. `prebuiltTemplate`: a formatted file system of fixed size (fallback A or B of [../02-design/android-image.md](../02-design/android-image.md) §5.2) |
| `partitions` | array | yes | 1 to 64 entries | GPT partitions in on-disk order |
| `partitions[].label` | string | yes | `[a-z][a-z0-9_]{0,35}` (GPT names hold 36 UTF-16 code units). Unique across all disks | the GPT name, seen as `/dev/block/by-name/<label>` |
| `partitions[].firstLBA` | integer | yes | a multiple of 2048 (1 MiB), at least 2048 | the first sector |
| `partitions[].size` | integer | yes | a multiple of 512, at least 512 | the size in bytes. Equals the source image size exactly ([../02-design/android-image.md](../02-design/android-image.md) §4.2) |
| `partitions[].sha256` | string | yes | 64 lowercase hex | SHA-256 of the partition contents. For blank partitions, the hash of zeros |

How ImageCore uses them ([../02-design/android-image.md](../02-design/android-image.md) §9.2):

- VZ attach order is `disks` in array order, then `templates` in array order. In v1 that is `os`, `persistent`, `userdata`.
- `os` is attached from the bundle, read-only, with caching `.automatic`. Each template is cloned once at provisioning into `Runtime/instance/<file name of path>` and attached read-write with synchronization `.full`.
- With `blankFormattable`, provisioning grows `userdata.img` to `runtime.userdataGiB` and moves the backup GPT ([../02-design/android-image.md](../02-design/android-image.md) §5.2). With `prebuiltTemplate`, the size stays `logicalSize` and Settings offers no size choice.
- ImageCore does not hash partitions. The file hash covers them. `bundle` checks them against `disks.json`, and the T2 disk test uses them.
- The disk and partition GUIDs are not in the manifest. They are derived (UUIDv5) and rewritten per instance ([../02-design/android-image.md](../02-design/android-image.md) §4.4, §5.1).

### 4.6 `consolePorts`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `index` | integer | yes | 0 to 31. Equals the array position | the guest `hvcN` number |
| `role` | string | yes | `systemConsole`, `log`, `silent`, or `service` | the default `ConsoleRole` ([../02-design/vm.md](../02-design/vm.md) §2) |
| `name` | string | yes | `[a-z][a-z0-9_]{0,31}`. Unique | the role's name, for example `logcat` |

- Exactly one port is `systemConsole`, and it is index 0.
- The manifest gives the default roles. `BootOptions` change them **by name**, never by index: developer mode turns `serial` into `.service("serial")`, and log capture turns `logcat` into `.log("logcat")` ([../02-design/android-image.md](../02-design/android-image.md) §7.1). If a name is missing, that option has no effect.
- `ConsolePortPlan` (RuntimeCore) orders the ports so that the guest numbering matches `index` ([../02-design/vm.md](../02-design/vm.md) §6.2).

### 4.7 `gpuProfiles`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `drmVirgl` | profile | yes | — | the default profile ([../02-design/graphics.md](../02-design/graphics.md) §9) |
| `guestSwiftshader` | profile | yes | — | Graphics Safe Mode (`graphics.safeMode`) |
| `headless` | profile | no | development bundles only (§7.3) | the no-GPU bring-up profile of `apkrun dev boot --gpu none` ([../02-design/android-image.md](../02-design/android-image.md) §9.1) |
| profile `.bootconfig` | object | yes | 0 to 64 entries. Keys and values as in §3.2 | bootconfig layer 2 keys added for this profile |
| profile `.overrides` | array of string | yes | 0 to 64 unique keys | keys of `bootconfig.txt` that this profile may override |
| profile `.requiredHostCapabilities` | array of string | yes | unique items, each `virgl` or `edid` | the virtio-gpu features the host device must offer: `virgl` = `VIRTIO_GPU_F_VIRGL`, `edid` = `VIRTIO_GPU_F_EDID` |

- `BootOptions.gpuProfile` picks one profile per boot. The others are ignored.
- The `drmVirgl` keys are verified names. The `guestSwiftshader` keys in §4.1 are placeholders until #013 copies them from the reference capture of that profile.

### 4.8 `requirements`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `minimumRuntimeVersion` | string | yes | `MAJOR.MINOR.PATCH`, no leading zeros | the oldest APKRun that may boot this image (release rule R3) |
| `guestProtocol.min` | integer | yes | 1 to 65535 | lowest guest protocol major the image's agents speak |
| `guestProtocol.max` | integer | yes | `min` to 65535 | highest major |
| `agents` | array | yes | 0 to 16 entries. Empty for `stock`. For `apkrun`, contains `io.apkrun.guest` and `io.apkrun.store` | agents built into the image |
| `agents[].package` | string | yes | an Android package name ([package-metadata-json.md](package-metadata-json.md) §2). Unique | agent package |
| `agents[].versionCode` | integer | yes | 1 to 9223372036854775807 | its `longVersionCode` |

- The host check is: `minimumRuntimeVersion` ≤ the APKRun version (`CFBundleShortVersionString`), and `min…max` intersects `guestProtocol.majors` of `components.json` ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1, §2.2). Failures: `incompatibleRuntime(required)`, `incompatibleProtocol(range)`.
- A stock image has no agents. The host installs the development Guest Agent from `Resources/guest/`, and reinstalls it when its `versionCode` differs ([../02-design/guest-protocol.md](../02-design/guest-protocol.md) §5.2).
- The migration health check expects each listed agent at its `versionCode` ([../02-design/android-image.md](../02-design/android-image.md) §12.3 step 5).

### 4.9 `userdata` and `compatibility`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `userdata.schemaVersion` | integer | yes | at least 1 | what `/data` and `/metadata` look like after this image boots them ([../02-design/android-image.md](../02-design/android-image.md) §12.1) |
| `userdata.upgradableFrom` | array of integer | yes | 1 to 64 items, ascending, unique, each at least 1. Contains `schemaVersion` | instance userdata schemas this image can boot |
| `compatibility.upgradeFrom.minimumImageVersion` | string | yes | short form (§2.1). At most the triple of `imageVersion` | the oldest current image that may migrate to this one (C4) |

- Provisioning writes `userdata.schemaVersion` into `instance.json`.
- Activation of an image whose `upgradableFrom` lacks the instance's schema gives `userdataSchemaUnsupported(instance, image)`. The way out is a newer image or Reset Android.
- A manual activation of an image whose `minimumImageVersion` is above the current image gives `migrationSourceTooOld(minimum)`. The feed never offers it (C4). Provisioning a new instance doesn't check `minimumImageVersion`.
- `minimumImageVersion` equal to this image's own triple means that no image may migrate to it. Only a new instance can use it. That is the `bundle` default.

### 4.10 `files`

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `path` | string | yes | `boot/`, `disks/`, `templates/`, or `legal/` followed by one name of `[a-z0-9][a-z0-9._-]{0,63}` | bundle-relative path |
| `size` | integer | yes | 1 to 1099511627776 (1 TiB) | size in bytes (the logical size of sparse files) |
| `sha256` | string | yes | 64 lowercase hex | SHA-256 of the whole file |

- Sorted by `path` in byte order. Paths are unique.
- The set of paths is exactly the set named by `boot`, `disks`, `templates`, and `legal` (S3). `manifest.json`, `manifest.sig`, and `SHA256SUMS` are not listed.

### 4.11 Encoding

- UTF-8 without a BOM. In practice all values are ASCII.
- Keys sorted by byte value at every level, two-space indentation, LF line ends, a final LF. Python: `json.dumps(m, sort_keys=True, indent=2) + "\n"`.
- At most 1 MiB.
- Readers never re-encode the file. The signature covers the exact bytes (§6.1).

## 5. JSON Schema

This schema is copied byte for byte into `Images/tools/schemas/runtime-image-manifest.schema.json` ([../02-design/android-image.md](../02-design/android-image.md) §1.2). `bundle` validates its output with it. The Swift `Codable` model in ImageCore plus the rules of §7.2 must accept exactly the same documents (§13).

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:apkrun:schema:runtime-image-manifest:1",
  "title": "APKRun RuntimeImageManifest, schema version 1",
  "type": "object",
  "additionalProperties": false,
  "required": ["schemaVersion", "imageVersion", "kind", "provenance", "guest", "boot", "disks", "templates", "consolePorts", "gpuProfiles", "requirements", "userdata", "compatibility", "files"],
  "properties": {
    "schemaVersion": { "const": 1 },
    "imageVersion": { "type": "string", "pattern": "^([0-9]{4})\\.(0[1-9]|1[0-2])\\.(0|[1-9][0-9]{0,2})-(cf[0-9]{1,20}|ar[0-9]{6})-(arm64)$" },
    "kind": { "enum": ["stock", "apkrun"] },
    "provenance": {
      "type": "object",
      "additionalProperties": false,
      "required": ["source", "android", "deviceFamily", "layout", "reference", "tools", "revisions", "pinnedManifestSHA256", "builderImageDigest"],
      "properties": {
        "source": {
          "type": "object",
          "additionalProperties": false,
          "required": ["origin", "branch", "target", "buildId", "archives"],
          "properties": {
            "origin": { "enum": ["ci.android.com", "apkrun-builder"] },
            "branch": { "type": "string", "pattern": "^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$" },
            "target": { "type": "string", "maxLength": 128, "pattern": "^[a-z0-9][a-z0-9_-]*-(user|userdebug|eng)$" },
            "buildId": { "type": "string", "pattern": "^([0-9]{1,20}|ar[0-9]{6})$" },
            "archives": {
              "type": "array",
              "minItems": 1,
              "maxItems": 8,
              "items": {
                "type": "object",
                "additionalProperties": false,
                "required": ["name", "size", "sha256"],
                "properties": {
                  "name": { "type": "string", "pattern": "^[A-Za-z0-9._+-]{1,255}$" },
                  "size": { "type": "integer", "minimum": 1 },
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
            "release": { "type": "string", "pattern": "^[1-9][0-9]*(\\.[0-9]+){0,2}$" },
            "sdk": { "type": "integer", "minimum": 1, "maximum": 10000 },
            "variant": { "enum": ["user", "userdebug", "eng"] },
            "securityPatch": { "type": "string", "pattern": "^[0-9]{4}-(0[1-9]|1[0-2])$" }
          }
        },
        "deviceFamily": { "type": "string", "maxLength": 64, "pattern": "^[a-z0-9]+(-[a-z0-9]+)*$" },
        "layout": {
          "type": "object",
          "additionalProperties": false,
          "required": ["path", "sha256"],
          "properties": {
            "path": { "$ref": "#/$defs/repoPath" },
            "sha256": { "$ref": "#/$defs/sha256" }
          }
        },
        "reference": { "anyOf": [{ "$ref": "#/$defs/repoPath" }, { "type": "null" }] },
        "tools": {
          "type": "object",
          "additionalProperties": false,
          "required": ["apkrunImage", "mkbootimg", "avbtool"],
          "properties": {
            "apkrunImage": { "$ref": "#/$defs/semver" },
            "mkbootimg": { "type": "string", "pattern": "^[0-9a-f]{40}$" },
            "avbtool": { "type": "string", "pattern": "^[0-9a-f]{40}$" }
          }
        },
        "revisions": {
          "type": "object",
          "additionalProperties": false,
          "required": ["imagesTools", "guest"],
          "properties": {
            "imagesTools": { "$ref": "#/$defs/treeRevision" },
            "guest": { "anyOf": [{ "$ref": "#/$defs/treeRevision" }, { "type": "null" }] }
          }
        },
        "pinnedManifestSHA256": { "anyOf": [{ "$ref": "#/$defs/sha256" }, { "type": "null" }] },
        "builderImageDigest": { "anyOf": [{ "type": "string", "pattern": "^sha256:[0-9a-f]{64}$" }, { "type": "null" }] }
      }
    },
    "guest": {
      "type": "object",
      "additionalProperties": false,
      "required": ["sdk", "abis", "targetSdkFloor"],
      "properties": {
        "sdk": { "type": "integer", "minimum": 1, "maximum": 10000 },
        "abis": {
          "type": "array",
          "minItems": 1,
          "maxItems": 8,
          "uniqueItems": true,
          "contains": { "const": "arm64-v8a" },
          "items": { "type": "string", "pattern": "^[a-z0-9_-]{1,32}$" }
        },
        "targetSdkFloor": { "type": "integer", "minimum": 1, "maximum": 10000 }
      }
    },
    "boot": {
      "type": "object",
      "additionalProperties": false,
      "required": ["kernel", "ramdisk", "bootconfig", "cmdline", "kernelPageSize", "bootconfigOverrides"],
      "properties": {
        "kernel": { "$ref": "#/$defs/bootFile" },
        "ramdisk": { "$ref": "#/$defs/bootFile" },
        "bootconfig": { "$ref": "#/$defs/bootFile" },
        "cmdline": { "$ref": "#/$defs/bootFile" },
        "kernelPageSize": { "enum": [4096, 16384, 65536] },
        "bootconfigOverrides": { "$ref": "#/$defs/keyList" }
      }
    },
    "disks": {
      "type": "array",
      "minItems": 1,
      "maxItems": 1,
      "prefixItems": [
        {
          "allOf": [
            { "$ref": "#/$defs/disk" },
            {
              "properties": {
                "role": { "const": "os" },
                "path": { "pattern": "^disks/" },
                "readOnly": { "const": true }
              },
              "not": { "required": ["userdataStrategy"] }
            }
          ]
        }
      ],
      "items": false
    },
    "templates": {
      "type": "array",
      "minItems": 2,
      "maxItems": 2,
      "prefixItems": [
        {
          "allOf": [
            { "$ref": "#/$defs/disk" },
            {
              "properties": {
                "role": { "const": "persistent" },
                "path": { "pattern": "^templates/" },
                "readOnly": { "const": false }
              },
              "not": { "required": ["userdataStrategy"] }
            }
          ]
        },
        {
          "allOf": [
            { "$ref": "#/$defs/disk" },
            {
              "properties": {
                "role": { "const": "userdata" },
                "path": { "pattern": "^templates/" },
                "readOnly": { "const": false }
              },
              "required": ["userdataStrategy"]
            }
          ]
        }
      ],
      "items": false
    },
    "consolePorts": {
      "type": "array",
      "minItems": 1,
      "maxItems": 32,
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["index", "role", "name"],
        "properties": {
          "index": { "type": "integer", "minimum": 0, "maximum": 31 },
          "role": { "enum": ["systemConsole", "log", "silent", "service"] },
          "name": { "type": "string", "pattern": "^[a-z][a-z0-9_]{0,31}$" }
        }
      }
    },
    "gpuProfiles": {
      "type": "object",
      "additionalProperties": false,
      "required": ["drmVirgl", "guestSwiftshader"],
      "properties": {
        "drmVirgl": { "$ref": "#/$defs/gpuProfile" },
        "guestSwiftshader": { "$ref": "#/$defs/gpuProfile" },
        "headless": { "$ref": "#/$defs/gpuProfile" }
      }
    },
    "requirements": {
      "type": "object",
      "additionalProperties": false,
      "required": ["minimumRuntimeVersion", "guestProtocol", "agents"],
      "properties": {
        "minimumRuntimeVersion": { "$ref": "#/$defs/semver" },
        "guestProtocol": { "$ref": "#/$defs/protocolRange" },
        "agents": {
          "type": "array",
          "maxItems": 16,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["package", "versionCode"],
            "properties": {
              "package": { "type": "string", "maxLength": 255, "pattern": "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$" },
              "versionCode": { "type": "integer", "minimum": 1, "maximum": 9223372036854775807 }
            }
          }
        }
      }
    },
    "userdata": { "$ref": "#/$defs/userdataCompatibility" },
    "compatibility": {
      "type": "object",
      "additionalProperties": false,
      "required": ["upgradeFrom"],
      "properties": {
        "upgradeFrom": {
          "type": "object",
          "additionalProperties": false,
          "required": ["minimumImageVersion"],
          "properties": {
            "minimumImageVersion": { "$ref": "#/$defs/shortImageVersion" }
          }
        }
      }
    },
    "legal": {
      "type": "object",
      "additionalProperties": false,
      "required": ["notice"],
      "properties": {
        "notice": { "allOf": [ { "$ref": "#/$defs/fileEntry" }, { "properties": { "path": { "pattern": "^legal/" } } } ] }
      }
    },
    "files": {
      "type": "array",
      "minItems": 1,
      "maxItems": 64,
      "items": { "$ref": "#/$defs/fileEntry" }
    }
  },
  "$defs": {
    "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
    "semver": { "type": "string", "pattern": "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" },
    "shortImageVersion": { "type": "string", "pattern": "^[0-9]{4}\\.(0[1-9]|1[0-2])\\.(0|[1-9][0-9]{0,2})$" },
    "treeRevision": { "type": "string", "pattern": "^[0-9a-f]{40}(-dirty)?$" },
    "repoPath": {
      "type": "string",
      "maxLength": 255,
      "pattern": "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$",
      "not": { "pattern": "(^|/)\\.{1,2}(/|$)" }
    },
    "bundlePath": { "type": "string", "pattern": "^(boot|disks|templates|legal)/[a-z0-9][a-z0-9._-]{0,63}$" },
    "fileEntry": {
      "type": "object",
      "additionalProperties": false,
      "required": ["path", "size", "sha256"],
      "properties": {
        "path": { "$ref": "#/$defs/bundlePath" },
        "size": { "type": "integer", "minimum": 1, "maximum": 1099511627776 },
        "sha256": { "$ref": "#/$defs/sha256" }
      }
    },
    "bootFile": {
      "allOf": [
        { "$ref": "#/$defs/fileEntry" },
        { "properties": { "path": { "pattern": "^boot/" } } }
      ]
    },
    "bootconfigKey": { "type": "string", "maxLength": 256, "pattern": "^[A-Za-z0-9_.-]+$" },
    "keyList": { "type": "array", "maxItems": 64, "uniqueItems": true, "items": { "$ref": "#/$defs/bootconfigKey" } },
    "gpuProfile": {
      "type": "object",
      "additionalProperties": false,
      "required": ["bootconfig", "overrides", "requiredHostCapabilities"],
      "properties": {
        "bootconfig": {
          "type": "object",
          "maxProperties": 64,
          "propertyNames": { "$ref": "#/$defs/bootconfigKey" },
          "additionalProperties": { "type": "string", "maxLength": 1024, "pattern": "^[\\x20\\x21\\x23-\\x5b\\x5d-\\x7e]*$" }
        },
        "overrides": { "$ref": "#/$defs/keyList" },
        "requiredHostCapabilities": { "type": "array", "uniqueItems": true, "items": { "enum": ["virgl", "edid"] } }
      }
    },
    "partition": {
      "type": "object",
      "additionalProperties": false,
      "required": ["label", "firstLBA", "size", "sha256"],
      "properties": {
        "label": { "type": "string", "pattern": "^[a-z][a-z0-9_]{0,35}$" },
        "firstLBA": { "type": "integer", "minimum": 2048, "multipleOf": 2048 },
        "size": { "type": "integer", "minimum": 512, "multipleOf": 512 },
        "sha256": { "$ref": "#/$defs/sha256" }
      }
    },
    "disk": {
      "type": "object",
      "additionalProperties": false,
      "required": ["role", "path", "readOnly", "identifier", "logicalSize", "partitions"],
      "properties": {
        "role": { "enum": ["os", "persistent", "userdata"] },
        "path": { "$ref": "#/$defs/bundlePath" },
        "readOnly": { "type": "boolean" },
        "identifier": { "type": "string", "pattern": "^[a-z0-9][a-z0-9-]{0,19}$" },
        "logicalSize": { "type": "integer", "minimum": 2097152, "maximum": 1099511627776, "multipleOf": 1048576 },
        "userdataStrategy": { "enum": ["blankFormattable", "prebuiltTemplate"] },
        "partitions": { "type": "array", "minItems": 1, "maxItems": 64, "items": { "$ref": "#/$defs/partition" } }
      }
    },
    "protocolRange": {
      "type": "object",
      "additionalProperties": false,
      "required": ["min", "max"],
      "properties": {
        "min": { "type": "integer", "minimum": 1, "maximum": 65535 },
        "max": { "type": "integer", "minimum": 1, "maximum": 65535 }
      }
    },
    "userdataCompatibility": {
      "type": "object",
      "additionalProperties": false,
      "required": ["schemaVersion", "upgradableFrom"],
      "properties": {
        "schemaVersion": { "type": "integer", "minimum": 1 },
        "upgradableFrom": { "type": "array", "minItems": 1, "maxItems": 64, "uniqueItems": true, "items": { "type": "integer", "minimum": 1 } }
      }
    }
  }
}
```

## 6. Signature and `SHA256SUMS`

### 6.1 `manifest.sig`

`manifest.sig` is an Ed25519 signature over the exact bytes of `manifest.json`, with a key ID in a small header ([../02-design/android-image.md](../02-design/android-image.md) §10.1). `feed.json.sig` uses the same format (§9).

```text
apkrun-signature-v1
key-id: 700e41b63eaee3c9
algorithm: ed25519
signature: Ii6yqtn26gB5SDj+amUWCNjW5BlbZDlJ/oGmsn9o4yQgEhgDNjiHlKbHm1iWq5WHfWuWSbOGC03i6M15G2iF/Q==
```

| Line | Rule |
|---|---|
| 1 | exactly `apkrun-signature-v1` |
| 2 | `key-id: ` + 16 lowercase hex digits = the first 8 bytes of SHA-256 over the raw 32-byte Ed25519 public key |
| 3 | exactly `algorithm: ed25519` |
| 4 | `signature: ` + standard base64 with padding of the 64-byte signature |

- ASCII, exactly four lines, each ending in LF. At most 4 KiB. Anything else gives `manifestInvalid(path: "manifest.sig", reason)`.
- The signed message is the bytes of `manifest.json` only. The header is not signed. A changed key ID only selects a different key, so the check still fails.
- **Trust store.** `ImageTrustStore` is a list of `(keyID, publicKey)` compiled into the app. Release builds contain the release image keys only. Debug builds, and the `ReleaseUpdateTest` builds of the maintenance tests ([../05-development/build-system.md](../05-development/build-system.md) §2.4), also contain the per-developer key: the build reads `~/.config/apkrun/dev-image-key.pub` (written by `python3 -m apkrun_image keygen --out ~/.config/apkrun/dev-image-key`, [../05-development/build-system.md](../05-development/build-system.md) §10.1) when it exists. `dev-image-key.pub` holds the base64 of the raw public key on one line. Each lab Mac has its own key the same way ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.5). Tests inject a store with `test-image-ed25519`.
- An unknown key ID gives `untrustedKey(keyID)`. A failed check gives `signatureInvalid(keyID)`.
- A compromised key is removed from `ImageTrustStore` in an APKRun release ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §10).

### 6.2 `SHA256SUMS`

```text
e158851fbebb402e1f18ea9372ea2f76b4dea23eceb5c4b92e5b27ade8537f5b  boot/bootconfig.txt
5f09fae74bfa7f97e26986705f4d193c67a8f6484fb3c6c4dfc40d011b9e0705  boot/cmdline.txt
6923dd1bc0460082c5d55a831908c24a282860b7f1cd6c2b79cf1bc8857c639c  boot/kernel
b522bcfff2ba6df0999d4772142b22165fff473d596d40915275f324f5c2322b  boot/ramdisk.img
840a8dcfeae95966a870b0b5257997ce94cbc19dd979409d1671d2e93a9e0de6  disks/os.img
1c61425b1ba94748e725edd6fbc902b80e08483116a8affb4b8829143e486f1e  templates/persistent.img
374298ce07e00296d99b3db8860b6ec7002c54d1b83796799a2686fd5bb0851b  templates/userdata.img
```

- One line per `files` entry, in the same order: 64 lowercase hex, two spaces, the path, LF.
- It exists so that `cd Images/<v> && shasum -a 256 -c SHA256SUMS` works in a shell ([../02-design/android-image.md](../02-design/android-image.md) §10.1). It is not signed, so ImageCore never trusts it. Full verification requires it to be byte-equal to the rendering of `files`. Otherwise: `manifestInvalid(path: "SHA256SUMS", reason)`.
- CI builds the fixture bundle twice and compares the two `SHA256SUMS` files (T1).

## 7. Verification

### 7.1 Order

The order is fixed: signature, then schema, then files ([../02-design/android-image.md](../02-design/android-image.md) §10.1).

| Step | Check | Failure (`ImageFailure`) |
|---|---|---|
| 1 | `manifest.json` ≤ 1 MiB and `manifest.sig` ≤ 4 KiB. The signature file parses (§6.1) | `manifestInvalid` |
| 2 | the key ID is in `ImageTrustStore` | `untrustedKey(keyID)` |
| 3 | the Ed25519 signature verifies | `signatureInvalid(keyID)` |
| 4 | the JSON parses. `schemaVersion` is known to this build (§11) | `manifestInvalid(path, reason)`. For a newer version the reason is "needs a newer APKRun" |
| 5 | the schema of that version (§5) | `manifestInvalid(path, reason)`, where `path` is the JSON pointer of the first error |
| 6 | the semantic rules S1–S14 (§7.2) | `manifestInvalid(path, reason)` |
| 7 | the directory holds exactly the metadata files and `files`. Each file's size matches | `missingFile(file)`, `unexpectedFile(file)`, `hashMismatch(file)` for a size difference |
| 8 | full depth only: each file's SHA-256 matches, and `SHA256SUMS` is consistent (§6.2) | `hashMismatch(file)`, `manifestInvalid` |

- **Quick** verification (`ImageStore.verify(_, depth: .quick)`) runs steps 1–7 before every boot. The result of steps 1–6 is cached for the life of the apkrund process, keyed by the inode, size, and modification time of `manifest.json`.
- **Full** verification (`.full`) runs steps 1–8 at every install and in `apkrun doctor --deep`.
- Compatibility checks follow at activation and before every boot ([../02-design/android-image.md](../02-design/android-image.md) §9.3): `incompatibleRuntime(required)`, `incompatibleProtocol(range)`, `userdataSchemaUnsupported(instance, image)`, `migrationSourceTooOld(minimum)` (activation only), `downgradeRejected(from, to)`.
- Codes, messages, and remediations are in [error-catalog.md](error-catalog.md) (domain `image`).

### 7.2 Semantic rules

| # | Rule |
|---|---|
| S1 | `imageVersion` parses (§2.2). Its base is `cf` + `provenance.source.buildId` for `ci.android.com`, or equals `buildId` for `apkrun-builder`. Its architecture is `arm64` |
| S2 | `kind` is `stock` exactly when `provenance.source.origin` is `ci.android.com` |
| S3 | Every path named in `boot`, `disks`, `templates`, and `legal` has one `files` entry with the same size and hash, and `files` has no other entries. Each disk's `logicalSize` equals its file size |
| S4 | `files` is sorted by path in byte order, with no duplicates |
| S5 | Partitions of each disk are in ascending `firstLBA` order and do not overlap. The last sector of each partition is at most `logicalSize / 512 − 34` (room for the backup GPT) |
| S6 | Partition labels are unique across all disks. Disk identifiers are unique |
| S7 | `consolePorts[i].index == i`. Exactly one `systemConsole`, at index 0. Names are unique |
| S8 | Each GPU profile's `overrides` lists only keys that the profile's `bootconfig` also sets |
| S9 | `guestProtocol.min ≤ guestProtocol.max` |
| S10 | `kind: stock` has no `agents`. `kind: apkrun` lists `io.apkrun.guest` and `io.apkrun.store`. Agent packages are unique |
| S11 | `userdata.upgradableFrom` is ascending and contains `userdata.schemaVersion` |
| S12 | `compatibility.upgradeFrom.minimumImageVersion` ≤ the triple of `imageVersion` |
| S13 | `kind: apkrun` has non-null `revisions.guest`, `pinnedManifestSHA256`, and `builderImageDigest`. `kind: stock` has them all null |
| S14 | `guest.sdk == provenance.android.sdk`. `guest.targetSdkFloor` is 23 for SDK 34 and 24 for SDK 35 or later |

Boot preparation adds the bootconfig and cmdline checks of §3.2 and §3.3 (`bootconfigConflict`, `bootconfigTooLarge`, `cmdlineTooLong`).

### 7.3 Build-time checks

`bundle` refuses to write a bundle, and the release workflow refuses to publish one, when:

- any of §5, S1–S14, §3.2, or §3.3 fails;
- layers 1 and 2 serialize to more than 16 KiB with any GPU profile;
- a partition hash differs from `disks.json`, or `kernelPageSize` differs from the kernel header;
- a bundle signed with a release key has an `androidboot.apkrun.test.*` key ([../02-design/android-image.md](../02-design/android-image.md) §6.2), a `-dirty` revision, a `headless` GPU profile, or `kind: stock`;
- two builds of the same inputs give different `SHA256SUMS` (CI, T1).

## 8. Release archive (`.aar`)

### 8.1 Format

- The release job packs the bundle directory of a bundle signed with the release image key: `aa archive -a lzfse -d Images/work/<buildId>/bundle -o <imageVersion>.aar` ([../05-development/build-system.md](../05-development/build-system.md) §10.2).
- Entries are relative to the bundle root (`manifest.json`, `boot/kernel`, …). There is no top-level directory.
- Only regular files and directories. Zero runs in `os.img` compress to almost nothing.
- The feed entry records the archive's `size` and `sha256`, and `expandedSize`: the sum of the sizes of all regular files in the archive, including the three metadata files.

### 8.2 Download

`ImageDownloader` downloads to `Cache/images/<imageVersion>.aar.partial` with `Range` and `If-Range`, hashes while it downloads, and renames to `.aar` when size and hash match. More bytes than `size` gives `imageArchiveSizeMismatch`. The free space must be at least archive size + `expandedSize` + 10 GiB, before downloading and before installing (`insufficientSpace`). Details: [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.4.

### 8.3 Install

`ImageStore.install(from: .archive(url))` ([../02-design/android-image.md](../02-design/android-image.md) §10.4, [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.5):

1. Check the archive SHA-256 against the feed entry (`imageArchiveHashMismatch`). A manual install (`apkrun image install <file.aar>`, Install from File…) has no feed entry and skips this step. Space: a feed install needs the archive size + `expandedSize` + 10 GiB free. A manual install needs the file size + 10 GiB before step 2, and step 2 stops with `insufficientSpace` when less than 10 GiB would be left ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.4).
2. Extract with the AppleArchive framework into `Images/.installing-<name>/`. `<name>` is the `imageVersion` of the feed entry, or `manual-` + 16 random hex digits for a manual install. Entry rules: regular files and directories only, relative paths inside the root, no `..`, no absolute paths, symlinks, hard links, devices, or FIFOs (`imageArchiveUnsafeEntry(path)`). Permissions are reset to 0644 and 0755. Extended attributes and ACLs are dropped.
3. Full verification (§7.1). For a feed install, the manifest's `imageVersion`, `requirements.minimumRuntimeVersion`, `requirements.guestProtocol`, and `userdata` must equal the feed entry (`imageFeedInvalid`, §9 rule 6).
4. Punch holes (`fcntl(F_PUNCHHOLE)`) over all-zero 1 MiB blocks of every file under `disks/` and `templates/`. The bytes do not change.
5. Rename the directory to `Images/<imageVersion>/`. An existing directory of that name is left alone and the install succeeds without a change, if its manifest bytes are identical. Otherwise the install fails with `unexpectedFile`.
6. Delete the archive.

An install changes neither `current` nor `previous`. An interrupted install leaves only `.installing-*`, which is deleted at the next start. A development directory install (`apkrun dev image install <dir>`) runs steps 3 and 5 on `clonefile` copies and then sets `current` ([../02-design/android-image.md](../02-design/android-image.md) §10.3).

## 9. Image feed

This section restates [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.1, which is authoritative for the client rules. §9.3 and §9.4 add the field constraints.

### 9.1 Location and example

- **Location:** `https://<updates host>/apkrun/images/<channel>/feed.json` and `feed.json.sig`, where the channel is `stable` or `beta` (OQ-01).

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "sequence": 57,
  "generatedAt": "2026-10-02T09:00:00Z",
  "expiresAt": "2026-11-01T09:00:00Z",
  "images": [
    {
      "imageVersion": "2026.10.0-ar000123-arm64",
      "kind": "apkrun",
      "publishedAt": "2026-10-02T09:00:00Z",
      "archive": { "url": "https://<updates host>/apkrun/images/2026.10.0-ar000123-arm64.aar",
                   "size": 1932735283, "sha256": "…" },
      "expandedSize": 9663676416,
      "requirements": { "minimumRuntimeVersion": "1.1.0", "guestProtocol": { "min": 1, "max": 1 } },
      "userdata": { "schemaVersion": 3, "upgradableFrom": [2, 3] },
      "upgradeFrom": { "minimumImageVersion": "2026.04.0" },
      "securityPatchLevel": "2026-09-05",
      "tzdataVersion": "2026b",
      "critical": false,
      "rolloutPercent": 100,
      "releaseNotesURL": "https://<updates host>/apkrun/android/2026.10.0.html"
    }
  ]
}
```

- `feed.json.sig` uses the same signature format and trust store as `manifest.sig` (`ImageTrustStore`, [../02-design/android-image.md](../02-design/android-image.md) §10.1). It signs the exact bytes of `feed.json`.

### 9.2 Client rules (`ImageFeedClient`)

1. HTTPS only. `feed.json` at most 1 MiB, `feed.json.sig` at most 4 KiB. Conditional GET with the stored ETag.
2. The signature is checked before parsing. An unknown key or a bad signature gives `imageFeedSignatureInvalid`, and the last accepted feed stays in effect.
3. `channel` must equal the requested channel.
4. **Replay and freeze protection:** `sequence` must be at least the highest sequence accepted for this channel (stored in `Images/update-state.json`). If it is equal, the bytes must be identical. A lower sequence gives `imageFeedReplayed`. A feed whose `expiresAt` has passed gives `imageFeedExpired` and is not used. The release workflow signs the feed again with a new sequence at least once a week, with `expiresAt = generatedAt + 30 days`.
5. Unknown fields are ignored. An unknown `schemaVersion` means the feed is not used, and a health warning says "Update APKRun to receive Android system updates."
6. The feed is only a pointer. The archive's SHA-256 and the manifest signature inside the archive are checked on their own ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.5), and the manifest's `imageVersion`, `requirements`, and `userdata` must equal the feed entry (`imageFeedInvalid` otherwise).

Candidate selection (C1–C7), the phases, the download, and the apply gate are in [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.2–§4.6.

### 9.3 Fields

Top level:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `schemaVersion` | integer | yes | `1` | feed format version (rule 5) |
| `channel` | string | yes | `stable` or `beta` | must equal the requested channel (rule 3) |
| `sequence` | integer | yes | 1 to 9007199254740991 | monotonic per channel (rule 4) |
| `generatedAt` | string | yes | RFC 3339 `date-time` in UTC (`Z`) | when the feed was signed |
| `expiresAt` | string | yes | RFC 3339 in UTC, later than `generatedAt` | after this time the feed is not used (rule 4) |
| `images` | array | yes | 0 to 256 entries | the published images |

Entry:

| Field | Type | Required | Constraints | Meaning |
|---|---|---|---|---|
| `imageVersion` | string | yes | full form (§2.1). The triple is unique in the feed | the image |
| `kind` | string | yes | `apkrun`. An entry with another value is skipped | only product images are published ([../05-development/build-system.md](../05-development/build-system.md) §10.2). C7 |
| `publishedAt` | string | yes | RFC 3339 in UTC | shown in Settings |
| `archive.url` | string | yes | absolute `https` URL, at most 2048 characters, no user info | the `.aar` (§8) |
| `archive.size` | integer | yes | 1 to `expandedSize` | archive bytes. The downloader stops above it |
| `archive.sha256` | string | yes | 64 lowercase hex | SHA-256 of the archive |
| `expandedSize` | integer | yes | at least `archive.size`, at most 1099511627776 | bytes after extraction (§8.1). Used for the space check |
| `requirements` | object | yes | `minimumRuntimeVersion` and `guestProtocol` exactly as in §4.8. No `agents` | C2, C3. Must equal the manifest (rule 6) |
| `userdata` | object | yes | exactly as in §4.9 | C4. Must equal the manifest (rule 6) |
| `upgradeFrom.minimumImageVersion` | string | yes | short form (§2.1) | C4. The release script copies it from the manifest's `compatibility.upgradeFrom` |
| `securityPatchLevel` | string | no | `YYYY-MM-DD` | the day-precise Android security patch level |
| `tzdataVersion` | string | no | four digits and one lowercase letter, for example `2026b` | the time zone database in the image |
| `critical` | boolean | yes | — | skips the rollout (C6) and gets the shorter reminders ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.6, §4.11) |
| `rolloutPercent` | integer | yes | 0 to 100 | C6 |
| `releaseNotesURL` | string | no | absolute `https` URL | "What's new" link |

- `securityPatchLevel` and `tzdataVersion` exist only in the feed. `ImageUpdateCoordinator` stores them in `Images/update-state.json` with the installed version. Settings → General and `image.current` show them for the current image. An image installed without a feed entry shows `provenance.android.securityPatch` (month only) and no tzdata version.
- Rule 6 compares `requirements.minimumRuntimeVersion`, `requirements.guestProtocol`, and `userdata` field by field. The manifest's `agents` are not in the feed.

### 9.4 Validation

- An entry that fails §9.3 other than by an unknown `kind`, or two entries with the same `(year, month, sequence)`, make the whole feed invalid (`imageFeedInvalid(detail)`). The last accepted feed stays in effect.
- Unknown fields are ignored at every level (rule 5). A new optional field keeps `schemaVersion` 1. A field a v1 client would misread raises it.
- Release checks before publishing: R3 and R7 of [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.3; the entry equals its manifest (rule 6 and `upgradeFrom`); `archive.size` and `sha256` equal the uploaded file.
- Test fixtures: `Tests/Fixtures/runtime-updates/image-feed/` (valid, tampered, replayed sequence, expired, [../04-plan/test-strategy.md](../04-plan/test-strategy.md)).

## 10. Related files

These files are defined elsewhere. They are listed here because readers confuse them with the manifest.

| File | What it is | Defined in |
|---|---|---|
| `APKRun.app/Contents/Resources/components.json` | the APKRun build's own versions. Its `guestProtocol.majors` is the host side of C3 and §4.8 | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §2.1 |
| `APKRun.app/Contents/Resources/compatibility.json` | the app compatibility database (Android apps, not images). Not related to the manifest's `compatibility` block | [../02-design/diagnostics.md](../02-design/diagnostics.md) §10 |
| `Images/manifests/<buildId>/android-image.json`, `inventory.json` | build-time descriptions of an Android build. Copied into `provenance` | [android-image-manifest.md](android-image-manifest.md) |
| `Images/update-state.json` | Android system update state | [../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §4.3 |
| `Runtime/instance/instance.json` | the VM instance, including the image version in use and the userdata schema | [../02-design/android-image.md](../02-design/android-image.md) §5.1 |

## 11. Versioning rules

- `schemaVersion` is an integer. Only `1` is defined. The schema `$id` carries the version.
- Unknown fields are rejected. Any change to the schema, even an optional field, raises `schemaVersion`. The manifest is ours and signed, so a mistake must fail.
- Installed manifests are signed and are never rewritten or migrated. So ImageCore keeps a decoder for **every** manifest schema version from 1 up. This differs from host data files, which are migrated ([../02-design/runtime-maintenance.md](../02-design/runtime-maintenance.md) §5).
- A manifest with a newer `schemaVersion` fails step 4 of §7.1. To keep that from reaching users, an image whose manifest uses schema version n must set `minimumRuntimeVersion` to an APKRun that reads n (a release check, together with R3).
- The signature format has its own version, in line 1 of the signature file (`apkrun-signature-v1`).
- The feed follows rule 5 of §9.2: unknown fields ignored, an unknown `schemaVersion` not used.
- The ImageVersion format (§2) is fixed. Changing it needs an ADR, because it is a directory name, a bootconfig value, and a sort key.

## 12. Writers and readers

| Role | Component | What |
|---|---|---|
| Writer | `python3 -m apkrun_image bundle` (`bundle.py`, `sign.py`) | `manifest.json`, `SHA256SUMS`, `manifest.sig`, and the bundle files |
| Writer | `python3 -m apkrun_image keygen` | the per-developer key pair in `~/.config/apkrun/` |
| Writer | the image release job | `<imageVersion>.aar` (`aa archive`), `feed.json` and `feed.json.sig` (`scripts/release/image-feed.py`, [../05-development/build-system.md](../05-development/build-system.md) §10.2) |
| Reader | ImageCore `ImageStore` (apkrund) | verification (§7), install (§8.3), garbage collection |
| Reader | ImageCore `AndroidBootPlanner`, `InstanceStore` | `boot`, `disks`, `templates`, `consolePorts`, `gpuProfiles` at boot and provisioning |
| Reader | RuntimeCore | `requirements` (activation, boot, migration health check) |
| Reader | APKStoreCore | `guest` before the first boot |
| Reader | `ImageFeedClient`, `ImageUpdateCoordinator` (apkrund) | the feed (§9) |
| Reader | DiagnosticsCore, the CLI (`apkrun image list`, `apkrun doctor`) | `imageVersion`, `kind`, `provenance` |

The manifest is written once, at build time. No runtime component writes it.

## 13. Tests and fixtures

| Tier | Test | Task |
|---|---|---|
| T0 | `ImageVersion`: parsing of valid and invalid strings, canonical rendering, ordering on the triple only, equal triples with different bases | #065 |
| T0 | the schema and S1–S14 over the fixtures, in Python and in Swift. The Swift model and the schema accept and reject the same files | #065 |
| T0 | `manifest.sig` parsing and Ed25519 vectors with `test-image-ed25519`, including an unknown key ID and a changed byte | #065, #087 |
| T0 | feed rules 1–6 and §9.4 over the feed fixtures | #087 |
| T1 | the fixture bundle built twice, identical `SHA256SUMS`. Install from a directory and from an `.aar`, hole punching, an extra file, a missing file, an unsafe archive entry, an interrupted install | #065 (directory), #058 (`.aar`), #087 (feed checks) |
| T2 | the stock bundle boots to `sys.boot_completed=1` ([ADR-0011](../01-architecture/decisions/0011-runtime-image-bundle.md) verification) | #065 |

Fixtures:

- `Images/tools/tests/fixtures/runtime-manifests/valid/*.json` and `invalid/*.json`, with an `.expected.txt` file per invalid case naming the step of §7.1 and the rule. Python and Swift share them.
- `Tests/Fixtures/runtime-updates/image-feed/` for the feed.
- `Tests/Fixtures/signing/test-image-ed25519` and `.pub` for signature vectors.
