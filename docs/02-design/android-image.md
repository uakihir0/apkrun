# Android Image Design (Images/tools + ImageCore)

| Field | Value |
|---|---|
| Status | Design baseline |
| Related | [vm.md](vm.md), [graphics.md](graphics.md), [guest-components.md](guest-components.md), [runtime-daemon.md](runtime-daemon.md), [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md), [../01-architecture/decisions/0003-cuttlefish-base-image.md](../01-architecture/decisions/0003-cuttlefish-base-image.md), [../01-architecture/decisions/0011-runtime-image-bundle.md](../01-architecture/decisions/0011-runtime-image-bundle.md), [../01-architecture/decisions/0015-direct-kernel-boot.md](../01-architecture/decisions/0015-direct-kernel-boot.md), [../03-reference/android-image-manifest.md](../03-reference/android-image-manifest.md), [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) |
| Tasks | #008–#017, #035, #058, #064, #065, #066, #087, #095 |

---

## 1. Responsibilities and split

Android image handling has two halves.

| Half | Where | Language | Runs on | Owns |
|---|---|---|---|---|
| Build-time image tooling | `Images/tools/` | Python 3.12 | developer Mac, Linux builder, CI | Fetching AOSP artifacts, inventory, `AndroidImageManifest`, boot image extraction, sparse → raw, GPT assembly, bootconfig baseline, runtime image bundles, bundle signing, reference boot capture and diff |
| Runtime | `Packages/ImageCore` | Swift | `apkrund` | Verifying and installing bundles, the image store (`current`/`previous`), the Android VM instance (disks, `instance.json`), per-boot initrd assembly, bootconfig merge, translating image + instance into the Android parts of a `VMDefinition`, recovery points, migration data steps |

Rules:

- No code, Swift or Python, opens an Android image file by a hard-coded name. File names come from the inventory, then the `AndroidImageManifest`, then the runtime image manifest.
- ImageCore never parses AOSP build outputs (boot image headers, sparse images, LZ4). It consumes only finished runtime image bundles ([ADR-0011](../01-architecture/decisions/0011-runtime-image-bundle.md)).
- ImageCore never starts a VM. Booting and health checks during a migration are orchestrated by RuntimeCore (§12.3).
- Original downloaded files are never modified. Derived files go to `Images/work/<buildId>/` in the source tree, or into the bundle.

Non-goals for v1: in-guest OTA, A/B slot switching, recovery mode, booting through U-Boot ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)), and more than one Android instance.

### 1.1 Pipeline overview

```text
ci.android.com build (or our AOSP builder, M5+)
  │ fetch (#008)                                  Images/work/<buildId>/download/
  ▼
inventory (#008) ──────────────────────────────▶ Images/manifests/<buildId>/inventory.json
  │
  ▼
AndroidImageManifest (#009) ───────────────────▶ Images/manifests/<buildId>/android-image.json
  │
  ├─ boot extraction (#010): kernel, ramdisk, cmdline, vendor bootconfig
  ├─ disk assembly (#011): os.img (GPT) + templates (persistent, userdata)
  ├─ bootconfig baseline (#012/#013): image-level keys
  │
  ▼
runtime image bundle (#065) + manifest.json + manifest.sig + SHA256SUMS
  │ dev: `apkrun dev image install <dir>`     release: signed archive via the image feed (#087)
  ▼
ImageCore: Images/<imageVersion>/  ──▶  Runtime/instance/ (clone disks, #066)
  │ before every boot
  ▼
per-boot initrd (ramdisk + merged bootconfig) + cmdline + disk list + console plan
  │
  ▼
VMDefinition (Android parts)  ──▶  RuntimeCore adds GPU device  ──▶  VirtualMachineCore
```

### 1.2 Tooling layout

```text
Images/
├── tools/
│   ├── pyproject.toml             # Python 3.12; pinned deps (lz4, cryptography, jsonschema, pytest)
│   ├── apkrun_image/
│   │   ├── __main__.py            # `python3 -m apkrun_image <command>`
│   │   ├── fetch.py               # Build API v4 client (§2)
│   │   ├── inventory.py           # content-based file classification (§3.1)
│   │   ├── manifest.py            # AndroidImageManifest model + schema validation (§3.2)
│   │   ├── bootimg.py             # boot / init_boot / vendor_boot parsing via vendored unpack_bootimg (§4.1)
│   │   ├── kernel.py              # decompression + arm64 Image header checks
│   │   ├── bootconfig.py          # parse, merge, serialize, trailer (§6)
│   │   ├── sparse.py              # Android sparse → raw (§4.3)
│   │   ├── lp.py                  # liblp (super) metadata reader, read-only (§3.1)
│   │   ├── avb.py                 # vbmeta digest via vendored avbtool (§6.2)
│   │   ├── gpt.py                 # GPT writer and reader (§4.4)
│   │   ├── layout.py              # data-driven disk plans (§4.2)
│   │   ├── bundle.py              # runtime image bundle writer (§10)
│   │   └── sign.py                # Ed25519 manifest signing
│   ├── layouts/
│   │   └── cuttlefish-phone-arm64.json   # disk plan + console port plan + bootconfig baseline for this device family
│   ├── schemas/
│   │   ├── android-image-manifest.schema.json
│   │   └── runtime-image-manifest.schema.json
│   ├── reference/
│   │   ├── capture.sh             # runs on the Linux reference host (§8)
│   │   ├── compare_boot.py
│   │   └── normalize.yaml         # rules that remove volatile values before diffing
│   ├── vendor/                    # pinned copies: mkbootimg.py, unpack_bootimg.py (Apache-2.0), avbtool.py (MIT)
│   └── tests/                     # pytest (T0/T1), synthetic fixtures
├── manifests/<buildId>/           # committed: inventory.json, android-image.json
├── reference/<buildId>/<profile>/ # committed: reference boot captures (§8)
├── reference/vz/<macOS build>/    # committed: VZ topology captures (vm.md §5)
└── work/<buildId>/                # git-ignored: downloads and derived artifacts
scripts/inventory-cuttlefish.py    # entry point (#008); calls apkrun_image.inventory
```

The vendored `mkbootimg` and `avbtool` revisions are pinned in `ThirdParty/ThirdParty.lock.json` like every other third-party input ([../05-development/build-system.md](../05-development/build-system.md) §6).

---

## 2. Acquisition (#008)

### 2.1 Selected source

| Item | Value |
|---|---|
| Site | ci.android.com (Android CI) |
| Branch | `aosp-android-latest-release` |
| Target | `aosp_cf_arm64_only_phone-userdebug` |
| Initial pinned build | `16373615` (2026-09-17) |
| Artifacts used | `aosp_cf_arm64_only_phone-img-16373615.zip` (device images). `cvd-host_package.tar.gz` only for the reference host (§8); its binaries are aarch64 Linux ELF and do not run on macOS. |
| Guest Android version | Android 17 (API 37). Confirmed from the boot image `os_version` field (§3.1) and `ro.build.version.sdk` in the reference capture. |

The pin is recorded in `Images/manifests/<buildId>/android-image.json` (`source` block). Moving to a new build is a normal change: fetch, inventory, rebuild the bundle, re-run the T2 boot suite and the reference diff.

### 2.2 Fetch tool

```bash
python3 -m apkrun_image fetch \
  --branch aosp-android-latest-release \
  --target aosp_cf_arm64_only_phone-userdebug \
  --build 16373615 \
  --artifact 'aosp_cf_arm64_only_phone-img-*.zip' \
  --out Images/work/16373615/download/
```

- Uses the Android Build API v4: `https://androidbuild-pa.googleapis.com/v4/builds/{buildId}/{target}/attempts/latest/artifacts` to list, and `…/artifacts/{name}/url` to get a signed download URL.
- The API key is the public key embedded in the open-source `cvd` tool (`android_build_api_key.cc`). The tool reads it from `APKRUN_ANDROID_BUILD_API_KEY`. The key is not committed. `docs/05-development/environment-setup.md` explains where to copy it from. Manual download from the ci.android.com web UI is the documented fallback; `fetch` then only verifies.
- Downloads resume with HTTP `Range`. After each download the tool records name, size, and SHA-256 in `Images/work/<buildId>/download/fetch.json`. The requested branch is recorded with `branchProvenance: "caller-asserted"` because the artifact-list request is scoped by build ID and target. It never overwrites an existing artifact unless an API or prior manifest hash verifies it.
- A second run with the same arguments downloads nothing and re-verifies hashes.

### 2.3 Licensing note

The prebuilt image is used for development only (M1–M4). Release images are built from source by us (§11) so that we control the notices and source offer. Redistribution questions are tracked in [../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md) and R-10.

---

## 3. Inventory and AndroidImageManifest (#008, #009)

### 3.1 Inventory (#008)

`scripts/inventory-cuttlefish.py <zip or directory> [--out inventory.json]` lists every archive entry and classifies it **by content**. When given a download directory with one archive and `fetch.json`, it inventories that archive and carries the checked build provenance into the inventory. An unpacked directory without fetch metadata is inventoried as a directory. File names are recorded only as hints. #008 requires filename, size, hash, and probable purpose. The tool records more.

| Detection | Test | Extra details recorded |
|---|---|---|
| Boot image | `ANDROID!` at offset 0 | header version (offset 40), kernel size, ramdisk size, `os_version` (Android release and security patch level), cmdline, and the bounded v4 boot signature size when present. Kernel size > 0 ⇒ `boot`; kernel size 0 and ramdisk > 0 ⇒ `init_boot`. |
| Vendor boot image | `VNDRBOOT` at offset 0 | header version 3 or 4; validate ramdisk and DTB bounds for both; for v4, page size, vendor cmdline, vendor ramdisk table (name, type NONE/PLATFORM/RECOVERY/DLKM, size), and bootconfig section size |
| vbmeta image | `AVB0` at offset 0 | algorithm, rollback index, flags, descriptors (hash, hashtree, chain partition names) |
| AVB footer | `AVBf` in the last 64 bytes | footer version, original image size, vbmeta offset and size |
| Android sparse image | little-endian magic `0xED26FF3A` at offset 0 | block size, total blocks (logical size), chunk count |
| Dynamic partition metadata | after unsparsing (streamed): liblp geometry magic at offset 4096 | logical partitions (name, size, group), block device size, metadata slots |
| Filesystems | ext4 `0xEF53` at 1024+56; erofs `0xE0F5E1E2` at 1024; f2fs `0xF2F52010` at 1024 | filesystem type, size |
| Text metadata | `android-info.txt`, `fastboot-info.txt` (UTF-8 text) | parsed key/values (`config=phone`, `gfxstream=supported`, …) |
| Anything else | — | `kind: unknown`. Unknown files are listed, never dropped. |

Output (`inventory.json`, one entry per file):

```json
{
  "path": "vendor_boot.img",
  "size": 67108864,
  "sha256": "…",
  "kind": "vendorBootImage",
  "probablePurpose": "vendor_boot partition (vendor ramdisk, vendor cmdline, bootconfig)",
  "details": { "headerVersion": 4, "ramdisks": [{ "name": "", "type": "PLATFORM", "size": 0 }], "bootconfigSize": 0 }
}
```

`probablePurpose` is derived from `kind` plus details, never from the file name alone. When name and content disagree (for example a file called `boot.img` that is a vendor boot image), the inventory flags `nameMismatch: true`.

Acceptance (#008): running the script on the pinned zip produces `Images/manifests/16373615/inventory.json`, committed, and a second run produces byte-identical output.

### 3.2 AndroidImageManifest (#009)

The inventory says *what is there*. The `AndroidImageManifest` says *what each thing is for*. It is written once per build (generated from the inventory by `python3 -m apkrun_image manifest`, then reviewed by a human and committed). Full schema and field rules: [../03-reference/android-image-manifest.md](../03-reference/android-image-manifest.md). The sketch below is abbreviated: hashes are elided, and it leaves out the artifacts `vbmeta_system`, `vbmeta_system_dlkm`, `vbmeta_vendor_dlkm`, and `custom` and five of the eight logical partitions. The complete example is in the reference, §5.

```json
{
  "schemaVersion": 1,
  "source": {
    "origin": "ci.android.com",
    "branch": "aosp-android-latest-release",
    "target": "aosp_cf_arm64_only_phone-userdebug",
    "buildId": "16373615",
    "archives": [{ "name": "aosp_cf_arm64_only_phone-img-16373615.zip", "size": 1476395008, "sha256": "…" }]
  },
  "android": { "release": "17", "sdk": 37, "variant": "userdebug", "securityPatch": "2026-09" },
  "architecture": "arm64",
  "deviceFamily": "cuttlefish-phone-arm64",
  "artifacts": [
    { "id": "boot",        "file": "boot.img",        "sha256": "…", "size": 67108864,   "kind": "bootImage",       "partition": "boot" },
    { "id": "init_boot",   "file": "init_boot.img",   "sha256": "…", "size": 8388608,    "kind": "bootImage",       "partition": "init_boot" },
    { "id": "vendor_boot", "file": "vendor_boot.img", "sha256": "…", "size": 67108864,   "kind": "vendorBootImage", "partition": "vendor_boot" },
    { "id": "vbmeta",      "file": "vbmeta.img",      "sha256": "…", "size": 65536,      "kind": "vbmeta",          "partition": "vbmeta" },
    { "id": "super",       "file": "super.img",       "sha256": "…", "size": 1879048192, "kind": "sparse",          "partition": "super" },
    { "id": "userdata",    "file": "userdata.img",    "sha256": "…", "size": 2166784,    "kind": "sparse",          "partition": "userdata" }
  ],
  "roles": {
    "kernel": "boot",
    "genericRamdisk": "init_boot",
    "vendorBoot": "vendor_boot",
    "vbmeta": ["vbmeta", "vbmeta_system", "vbmeta_system_dlkm", "vbmeta_vendor_dlkm"],
    "super": "super",
    "userdataTemplate": "userdata"
  },
  "logicalPartitions": [
    { "name": "system_a", "size": 897581056, "filesystem": "erofs" },
    { "name": "product_a", "size": 402653184, "filesystem": "erofs" },
    { "name": "vendor_a", "size": 150994944, "filesystem": "erofs" }
  ],
  "blankPartitions": [
    { "partition": "misc",     "size": 1048576 },
    { "partition": "metadata", "size": 67108864 },
    { "partition": "frp",      "size": 1048576 }
  ],
  "androidInfo": { "config": "phone", "gfxstream": "supported" }
}
```

The fields #009 asks for map as follows:

| #009 field | Manifest field |
|---|---|
| build ID | `source.buildId` |
| Android version | `android.release`, `android.sdk` |
| architecture | `architecture` |
| boot image | `roles.kernel` (+ `roles.genericRamdisk`: `init_boot` holds the generic ramdisk on Android 13+ devices) |
| vendor boot | `roles.vendorBoot` |
| super/system, vendor, product | `roles.super` + `logicalPartitions` (system, system_ext, product, vendor, vendor_dlkm, odm, odm_dlkm, system_dlkm are logical partitions inside `super`) |
| userdata | `roles.userdataTemplate` (used only by fallback A, §5.2) |
| vbmeta | `roles.vbmeta` (the top-level vbmeta and its chained images) |
| metadata | `blankPartitions[metadata]`. The zip ships no metadata image; the partition is created blank. |

Sizes of blank partitions are placeholders until #011 reads the real ones from the reference capture (§8). `android.sdk` comes from a small table keyed by the `os_version` release (17 → 37) and is cross-checked against `ro.build.version.sdk` in the reference capture.

### 3.3 Validation

The same JSON Schema (`Images/tools/schemas/android-image-manifest.schema.json`) is enforced by Python (`jsonschema`) and by a Swift `Codable` model in ImageCore. ImageCore uses that model only to read the provenance embedded in runtime manifests and in tests. The order is M1 (`schemaVersion`) first, so that a newer file gets a useful message, then the schema, then the semantic checks M2–M13. A newer `schemaVersion` is refused. `Images/tools` reads only the current version, and a change that raises it rewrites every committed manifest in the same change. The table fixes the messages of M1–M7. M8–M13 and the full order are in the reference, §8 and §10.

| # | Check | Error message pattern (actionable) |
|---|---|---|
| M1 | `schemaVersion` known | `android-image.json: schemaVersion 3 is newer than this tool supports (1). Update Images/tools.` |
| M2 | Every role points to an existing artifact `id` | `roles.vendorBoot = "vendor_boot2": no artifact with that id. Known ids: boot, init_boot, …` |
| M3 | Artifact kind matches role | `artifacts[2] (role vendorBoot): expected kind vendorBootImage v4, found bootImage v4. Is the file swapped?` |
| M4 | File exists, size and SHA-256 match | `super.img: SHA-256 mismatch (expected …, got …). Re-run fetch or re-inventory.` |
| M5 | `architecture == arm64` | `architecture x86_64 is not supported. Use an arm64 target.` |
| M6 | Boot header versions supported (boot/init_boot v4, vendor_boot v4) | `vendor_boot.img header v3 is not supported (needs v4 ramdisk table).` |
| M7 | No duplicate partition names | `partition "misc" appears in artifacts[7] and blankPartitions[0].` |

Invalid fixture manifests live in `Images/tools/tests/fixtures/manifests/invalid/`, each with the expected message. Both the Python and the Swift tests run over the same fixtures. The Swift test skips the checks that read image files, which are listed in `invalid/python-only.txt` (acceptance of #009: "invalid manifests fail with actionable errors").

---

## 4. Boot artifacts and GPT disk layout (#010, #011)

### 4.1 Boot artifact extraction (#010)

Command: `python3 -m apkrun_image extract --manifest Images/manifests/<buildId>/android-image.json --out Images/work/<buildId>/boot/`.

| Output | How it is made |
|---|---|
| `kernel` | Kernel section of the `roles.kernel` boot image. Compression is detected by magic: gzip `1f 8b`, LZ4 legacy `02 21 4c 18`, LZ4 frame `04 22 4d 18`. The kernel is decompressed if needed, because the arm64 kernel has no self-decompressor and `VZLinuxBootLoader` hangs on a compressed kernel. The result must have the arm64 Image magic `ARM\x64` at offset 0x38. `text_offset`, `image_size`, and the page-size bits of `flags` (bits 1–2: 4K/16K/64K) are recorded. |
| `ramdisk.img` | Vendor ramdisk fragments from the `vendor_boot` v4 table, in table order, excluding type `RECOVERY`, followed by the generic ramdisk from `init_boot`. This matches the load order vendor ramdisks → generic ramdisk → bootconfig. Fragments are concatenated byte for byte, as a bootloader does; the kernel unpacks concatenated compressed cpio archives. |
| `vendor-bootconfig.txt` | The bootconfig section of `vendor_boot` (for build 16373615: `androidboot.hardware=cutf_cvm` and `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384`). It becomes layer 1 of the bootconfig merge (§6.1). `extract` does not write the bundle's `boot/bootconfig.txt`; `bundle` (§10.2) writes it from this file and the layout. |
| `cmdline.txt` | Vendor cmdline (`printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig`) + the boot image cmdline (normally empty) + the APKRun additions, `cmdline.additions` of the layout file (§6.4). |
| `dtb` | Extracted for the record only. VZ provides its own device tree, so the DTB is not used. |
| `extraction.json` | Input and output SHA-256 values and sizes, tool versions (vendored `unpack_bootimg.py` revision), header fields, the ramdisk table (each fragment with its type and whether it was included), kernel header fields |

#010 acceptance: output includes kernel, ramdisk, extraction metadata, and hashes. Inputs are opened read-only and re-hashed after extraction to prove they were not changed. #010 records the kernel compression, the fragment list, and the command-line length of the pinned build in the verification log (§17).

The ramdisk fragment policy (all non-recovery fragments, table order) is what a default AOSP bootloader does when no board-specific selection applies. #013 confirms it against the reference capture by comparing the first-stage module list (`lsmod` and the first-stage init log).

### 4.2 Disk plan (#011)

Cuttlefish under crosvm gives the guest composite disks whose GPT partition names first-stage init and fstab rely on (`/dev/block/by-name/<name>`). APKRun builds raw GPT disk images with the same partition names. The mapping is data (`Images/tools/layouts/cuttlefish-phone-arm64.json`), copied into the runtime manifest, and read by ImageCore. Nothing in Swift lists partitions.

Design rules:

1. **Names mirror Cuttlefish's `os_composite`.** A/B partitions exist only as `_a` (slot `_a` is fixed by bootconfig). Single partitions keep their plain names.
2. **Read-only system disk.** Everything Android never writes in normal operation goes into `os.img`, attached read-only. This is APKRun's read-only base disk.
3. **Writable state split by lifetime.** `persistent.img` holds small writable partitions that belong to the instance (misc, metadata, frp). `userdata.img` holds `/data`. Both are per-instance clones (§5).
4. **Partition size = image size, exactly.** AVB hash footers sit in the last 64 bytes of a *partition*. A partition larger than its image would move the footer away from where libavb looks. `super` is sized to the unsparsed logical size recorded in its sparse header, because liblp checks the block device size.
5. **Partitions not needed on VZ are left out.** `uboot_env`, the persistent `bootconfig` partition, and the persistent vbmeta (AVB persistent values) serve U-Boot only. `android_esp` serves EFI boot only. `pvmfw_a` and `vvmtruststore` serve protected VMs (`hypervisor.vm.supported=0`). `hibernation` is unused. Each omission is confirmed in #011 against the reference `ls -l /dev/block/by-name` and the fstab. If an omitted partition turns out to be required, it is added blank.

Initial plan (confirmed or corrected by #011, and each correction is recorded in §13):

| VZ disk (attach order) | File | Access | `blockDeviceIdentifier` | GPT partitions (label ← source) | Guest name |
|---|---|---|---|---|---|
| 0 | `Images/<v>/disks/os.img` | read-only | `apkrun-os` | `boot_a` ← boot.img · `init_boot_a` ← init_boot.img · `vendor_boot_a` ← vendor_boot.img · `vbmeta_a` ← vbmeta.img · `vbmeta_system_a` ← vbmeta_system.img · `vbmeta_system_dlkm_a` ← vbmeta_system_dlkm.img · `vbmeta_vendor_dlkm_a` ← vbmeta_vendor_dlkm.img · `super` ← super.img (unsparsed) · `custom` ← cuttlefish_example_custom.img | `/dev/block/by-name/<label>` |
| 1 | `Runtime/instance/persistent.img` | read-write | `apkrun-persist` | `misc` ← blank · `metadata` ← blank · `frp` ← blank | same |
| 2 | `Runtime/instance/userdata.img` | read-write | `apkrun-data` | `userdata` ← blank (primary) or template (§5.2) | same |

Notes:

- `boot_a`, `init_boot_a`, and `vendor_boot_a` are not read by the direct boot itself; the kernel and ramdisk come from `boot/`. They are present because vbmeta describes them and because Android components (update_verifier, the boot control HAL, dumpstate) may open them. They cost no extra space in the bundle download beyond the images themselves.
- If #013/#014 show that a component needs `_b` partitions to exist, equal-sized zero-filled `_b` partitions are added. On APFS they are holes and cost nothing.
- The identifiers are for logs and host-side lookups only. Android finds partitions by GPT name.

### 4.3 Sparse to raw

`sparse.py` implements the Android sparse format directly (28-byte file header, magic `0xED26FF3A`, 12-byte chunk headers; RAW `0xCAC1`, FILL `0xCAC2`, DONT_CARE `0xCAC3`, CRC32 `0xCAC4`):

- The output is written straight into the partition's range inside `os.img`. There is no intermediate file.
- DONT_CARE chunks and zero FILL chunks become holes (`seek`), so `os.img` uses only as much physical space as the data.
- CRC32 chunks are verified when present. The total block count must equal the header's `total_blks`.
- T1 test: for the fixture sparse images and for the real `super.img`, the output hash equals `simg2img` output produced once on the Linux builder (the expected hash is committed in the test data).

### 4.4 GPT writer

`gpt.py` writes and reads GPT for 512-byte logical sectors (the VZ virtio-blk sector size is confirmed with `blockdev --getss` in #005 and #011):

- Protective MBR, primary header at LBA 1, 128 entries × 128 bytes at LBA 2–33, backup entries and backup header at the end of the disk, CRC32 over header and entry array.
- Partitions start on 1 MiB boundaries. Sizes follow rule 4 of §4.2.
- Type GUID: Linux filesystem data (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`) for every partition. Android does not look at type GUIDs.
- Unique partition GUIDs and the disk GUID are deterministic: UUIDv5 over (`imageVersion`, disk role, label) for `os.img` and the templates. Per-instance disks get new disk GUIDs at provisioning (§5.1) so that two instances would never collide.
- Names: UTF-16LE, at most 36 code units, case-sensitive.
- Reader side: the same module parses GPTs for tests and for `apkrun_image inspect`. ImageCore has its own minimal GPT reader/writer in Swift for §5.2 (header relocation only, no partition creation), tested against Python-produced fixtures.

### 4.5 Assembly and verification

`python3 -m apkrun_image disks --manifest … --layout layouts/cuttlefish-phone-arm64.json --out Images/work/<buildId>/disks/` produces `os.img`, `persistent.img`, `userdata.img` and `disks.json` (per partition: label, first LBA, size, source, SHA-256 of the partition contents).

#011 acceptance ("Android kernel detects expected virtio block devices") is checked twice:

1. T2 with the Linux test guest ([vm.md](vm.md) §12): the three disks are attached, and `/init` prints `PARTNAME` from `/sys/class/block/vd*/uevent` and the size of each partition. The test compares them with `disks.json`.
2. T2 with the Android kernel (#012): the console log shows `virtio_blk` detecting three disks with the expected partition counts.

---

## 5. Instance disks (#066, #011)

### 5.1 Provisioning

The instance is created on first run (#066) or by "Reset Android" (FR-OPS). Steps, all inside `Runtime/instance/`:

1. Create `instance.json` with a new instance UUID, `VZGenericMachineIdentifier`, a locally administered MAC, CPU/memory sizing ([vm.md](vm.md) §10), `imageVersion`, `userdataSchemaVersion` from the image manifest, and a new `userdataGeneration` UUID. APKStoreCore compares that generation with its package records to find packages that must be reinstalled ([package-store.md](package-store.md) §9.2). Restoring a recovery point (§12.2) also writes a new `userdataGeneration`.
2. `clonefile(2)` `Images/<v>/templates/persistent.img` → `persistent.img`, and `templates/userdata.img` → `userdata.img`. Clones are instant on APFS and share blocks until written. If the Application Support volume is not APFS, provisioning fails with `ImageFailure.cloneUnsupported` (APKRun does not fall back to full copies of multi-GB files; NFR-RES).
3. Give both disks new disk GUIDs and partition GUIDs (derived from the instance UUID) and rewrite the GPT CRCs.
4. Grow `userdata.img` to the configured size (§5.2).
5. `fsync` the files and the directory, then write `instance.json` last. An `instance.json` without its disks means an interrupted provisioning, and provisioning starts over.

### 5.2 userdata: format, size, growth

Primary approach: **blank userdata, formatted by Android on first boot.**

- The template holds a GPT with one `userdata` partition and no data (the file is all holes).
- At provisioning ImageCore extends the file with `ftruncate` to the configured size (sparse, so no physical space is used). It then moves the GPT backup header and entry array to the new last LBAs, updates `alternate_lba` and `last_usable_lba` in the primary header, extends the `userdata` partition's `ending_lba` to the new last usable LBA, and recomputes the CRCs.
- Cuttlefish's fstab marks `/data` (and `/metadata`) `formattable`. On first boot, fs_mgr/vold format the empty partition at its full size. This must be confirmed in #011 from `/vendor/etc/fstab.*` in the reference capture, together with the metadata encryption path (`keydirectory=/metadata/vold/metadata_encryption`).

Fallbacks, used only if first-boot formatting fails under VZ:

- **Fallback A:** use the zip's `userdata.img` (unsparsed) as the template. Its size is fixed at build time, so growth is not offered.
- **Fallback B:** the Linux builder creates a formatted template with `make_f2fs` at the default size, stored sparse in the bundle. Size fixed, no growth.

Sizes (settings key `runtime.userdataGiB`, [../03-reference/configuration.md](../03-reference/configuration.md)):

| | Value |
|---|---|
| Default | 32 GiB logical (physical usage grows with use) |
| Minimum | 8 GiB |
| Maximum | 256 GiB, and at most the free space on the volume at provisioning time minus a margin of 10 GiB |

Growing an existing, formatted userdata requires an offline `resize.f2fs`, which the guest cannot run on its own mounted `/data` and the host cannot run natively. v1 therefore fixes the size at provisioning. Changing it means "Reset Android" (recreate) after the user confirms data loss. Online growth is post-v1.

### 5.3 `androidboot.boot_devices`

First-stage init creates `/dev/block/by-name/*` links only for block devices under a device named in `androidboot.boot_devices` (or `androidboot.boot_device`), read from bootconfig. The match is on the **platform device** that the block device hangs off, or on a PCI prefix for PCI-only paths. crosvm on arm64 uses `10000.pci`, its PCI host bridge's platform device.

On VZ all virtio-blk devices sit behind the single `pci-host-ecam-generic` bridge at `0x40000000` ([vm.md](vm.md) §5), so one value covers all three disks.

Discovery (#011):

1. Boot the Linux test guest with the three disks. `/init` prints `readlink -f /sys/block/vda` (expected shape: `/sys/devices/platform/<addr>.<node>/pci0000:00/0000:00:NN.0/virtioM/block/vda`).
2. The platform component (for example `40000000.pci` or `40000000.pcie`, depending on the DT node name) is the value.
3. The value is stored with the topology capture in `Images/reference/vz/<macOS build>/topology.txt`, and compiled into ImageCore as `VZPlatformProfile.bootDevices` (host-platform data, not image data). The T2 suite re-checks it on every new macOS build (R-16).
4. The Android boot (#013) confirms that `/dev/block/by-name/` contains every label from §4.2.

Alternative if the path is not stable across macOS versions: `androidboot.boot_part_uuid`. It names one partition's unique GUID and makes that partition's *disk* the boot device, so it only works if all partitions are on one disk. The fallback layout would merge `persistent.img` into `userdata.img` (one read-write disk) and put `super` on the same disk. That is kept as a documented fallback, not built unless needed.

---

## 6. Bootconfig and command line (#010, #012, #013)

### 6.1 Layers and merge

Android 12+ reads `androidboot.*` from bootconfig, exposes it at `/proc/bootconfig`, and mirrors it as `ro.boot.*`. The kernel reads exactly one bootconfig block, the one at the end of the initrd. So ImageCore builds the whole block before each boot from four layers:

| Layer | Stored in | Produced by | Examples |
|---|---|---|---|
| 1. Vendor | `boot/bootconfig.txt` (section `[vendor]`) | `bundle` (§10.2), from `vendor-bootconfig.txt` (#010) | `androidboot.hardware`, vsock packet buffer size |
| 2. Image | `boot/bootconfig.txt` (section `[image]`) and `gpuProfiles` in the manifest | `bundle` (§10.2), from the layout file, the `avb.py` values, and the reference capture | slot, AVB, fstab suffix, HAL/APEX selection, graphics props |
| 3. Platform | ImageCore `VZPlatformProfile` | host app | `androidboot.boot_devices` |
| 4. Instance | computed at boot | ImageCore | serial number, density, memory size, APKRun flags |

Merge rules:

- A key may appear in exactly one layer. An identical duplicate is dropped with a debug log.
- A key in a later layer that conflicts with an earlier one is an error (`ImageFailure.bootconfigConflict(key, layerA, layerB)`), unless the later layer lists the key in its `overrides` array. Overrides are rare and each one carries a comment in the layout file.
- Keys must match `[A-Za-z0-9_.-]+`. Values must be printable ASCII without `"`, backslash, or newline, and are always written double-quoted.
- The serialized block must be at most 32 KiB (kernel limit). The build tool fails above 16 KiB to leave room for layers 3–4.

### 6.2 Key catalogue (initial)

"Reference" means the value is copied from the reference capture (§8) with the target profile, and the exact value is filled in during #013. The table is the checklist; the layout file is the source of truth.

| Key | Value | Layer | Status |
|---|---|---|---|
| `androidboot.hardware` | `cutf_cvm` | 1 | verified (vendor_boot) |
| `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size` | `16384` | 1 | verified |
| `androidboot.slot_suffix` | `_a` | 2 | decided (ADR-0015) |
| `androidboot.force_normal_boot` | `1` | 2 | reference |
| `androidboot.verifiedbootstate` | `orange` | 2 | decided for dev images; production in §11.4 |
| `androidboot.vbmeta.device_state` | `unlocked` | 2 | same |
| `androidboot.vbmeta.{digest,hash_alg,size,avb_version,invalidate_on_error}` | computed by `avb.py` (`avbtool calculate_vbmeta_digest` over vbmeta and its chained images) | 2 | computed at build time |
| `androidboot.fstab_suffix` | one of `cf.f2fs.hctr2`, `cf.f2fs.cts`, `cf.ext4.hctr2`, `cf.ext4.cts` | 2 | reference |
| `androidboot.console`, `androidboot.serialconsole` | reference (the Android shell console is on hvc1) | 2 | reference |
| `androidboot.hw_timeout_multiplier` | reference; may be raised while #095 investigates slow HALs | 2 | reference |
| `androidboot.hypervisor.vm.supported` | `0` | 2 | verified (arm64 default) |
| `androidboot.vendor.apex.com.android.hardware.keymint` | in-guest non-secure KeyMint APEX (§7.2) | 2 | reference with `--secure_hals=guest_keymint_insecure` |
| `androidboot.vendor.apex.com.android.hardware.gatekeeper` | in-guest non-secure Gatekeeper APEX (§7.2) | 2 | reference with `--secure_hals=guest_gatekeeper_insecure` |
| `androidboot.vendor.apex.com.android.hardware.graphics.composer` | the ranchu HWC APEX used with `drm_virgl` | 2 (GPU profile) | reference |
| `androidboot.vendor.apex.com.google.cf.vulkan` | per GPU profile (none for `drm_virgl`) | 2 (GPU profile) | reference |
| Graphics props (`androidboot.hardware.egl=mesa`, `…gralloc=minigbm`, `…hwcomposer=ranchu`, `…hwcomposer.mode=client`, `…hwcomposer.display_finder_mode=drm`, `androidboot.cpuvulkan.version=0`, `androidboot.opengles.version=196608`) | as listed for `drm_virgl`; the `guest_swiftshader` profile has its own set ([graphics.md](graphics.md) §9) | 2 (GPU profile) | verified names, exact keys from reference |
| `androidboot.wifi_impl` | reference; see §7.4 | 2 | #095 |
| `androidboot.modem_simulator_ports`, `androidboot.vsock_*_port`, `androidboot.vsock_*_cid` | omitted unless we provide the service (§7.3) | 2 | #095 |
| `androidboot.boot_devices` | `VZPlatformProfile.bootDevices` (§5.3) | 3 | #011 |
| `androidboot.serialno` | `APKRUN` + first 10 hex digits of the instance UUID, upper case | 4 | decided |
| `androidboot.lcd_density` | density of display 0 = 160 × backing scale ([display-and-windowing.md](display-and-windowing.md)) | 4 | decided |
| `androidboot.ddr_size` | VM memory size, in the reference's format | 4 | reference |
| `androidboot.apkrun.instance` | instance UUID | 4 | decided |
| `androidboot.apkrun.devmode` | `0` or `1` (custom image only, §11.3) | 4 | decided |
| `androidboot.apkrun.image` | `imageVersion` | 4 | decided |
| `androidboot.apkrun.test.*` | test image bundles only, never in release bundles (a CI check on the release manifest): `marker=<value>` identifies a test bundle in the migration test (§12.4); `fail_health=1` makes the Guest Agent report unhealthy (§12.4); `fail_boot=1` makes the product's init stop `zygote` before `sys.boot_completed`, so the boot times out ([diagnostics.md](diagnostics.md) §12 T2-4) | 2 (test layout of test bundles) | decided |

### 6.3 Trailer and per-boot initrd

Kernel layout: `[initrd][bootconfig text][NUL padding to a 4-byte boundary][size: le32][checksum: le32]["#BOOTCONFIG\n"]`. `size` counts the text plus padding. `checksum` is the 32-bit sum of those bytes (`xbc_calc_checksum`). The cmdline must contain `bootconfig` (the vendor cmdline already does).

Before every boot ImageCore:

1. Merges the layers (§6.1) into text.
2. `clonefile`s `Images/<v>/boot/ramdisk.img` to `Runtime/instance/boot/initrd.img.tmp`. Appending the trailer then rewrites only the last block (copy-on-write).
3. Appends text, padding, size, checksum, and magic; `fsync`s; renames to `initrd.img`.
4. Records the SHA-256 of the merged bootconfig text in the boot record (diagnostics).

The Python `bootconfig.py` and Swift `BootconfigWriter` share golden test vectors (`Images/tools/tests/fixtures/bootconfig/*.txt` → `*.bin`). The Linux test guest checks one of them end to end: it boots with a trailer and prints `/proc/bootconfig` (T2, #012).

### 6.4 Kernel command line

`cmdline.txt` = vendor cmdline + boot cmdline + APKRun additions. The additions start with:

- `console=hvc0`. crosvm adds this itself, so the Cuttlefish images do not carry it.
- Anything else that `/proc/cmdline` in the reference capture shows beyond the vendor cmdline and that is not bootconfig-able (non-`androidboot` kernel parameters). Each addition is listed in the layout file with a comment on where it came from.

`androidboot.*` parameters are never put on the cmdline. The total length must fit the VM validation limit of 2048 bytes ([vm.md](vm.md) §3).

---

## 7. Cuttlefish host-service substitution (#095)

Cuttlefish's guest expects host processes (launcher, `secure_env`, `modem_simulator`, rootcanal, GNSS proxy, sensors simulator, `socket_vsock_proxy`, …) that APKRun does not run. #095 decides, port by port and service by service, what APKRun provides instead. Guiding rule: **prefer in-guest implementations selected by configuration over host-side re-implementations**, and do not remove guest services unless they are shown to break boot, stability, or resource use (#035: "Do not aggressively remove services").

### 7.1 Console port plan

Cuttlefish attaches 20 single-port virtio-console devices. Some HALs open fixed `/dev/hvcN` nodes, so the numbering must match. APKRun attaches all 20 ports in the same order, after the numbering check in [vm.md](vm.md) §6.2. The plan is data in the runtime manifest (`consolePorts`), turned into `ConsolePortDefinition`s by ImageCore.

| Port | Cuttlefish use | APKRun role (v1) | Notes |
|---|---|---|---|
| hvc0 | kernel console | `.systemConsole` → `console.log` + `BootPhaseDetector` | `console=hvc0` |
| hvc1 | serial (Android shell console) | `.silent("serial")`; `.service("serial")` for `apkrun dev console --android-shell` in developer mode | |
| hvc2 | logcat | `.log("logcat")` in developer mode, and for the next boot after a failed boot (capture into `guest/logcat-<timestamp>.log`, [diagnostics.md](diagnostics.md) §8.3); else `.silent` | the guest writes whether or not the host reads |
| hvc3 | keymaster (legacy remote) | `.silent` | replaced by in-guest KeyMint (§7.2) |
| hvc4 | gatekeeper (remote) | `.silent` | replaced by in-guest Gatekeeper |
| hvc5 | Bluetooth (rootcanal) | `.silent` | no Bluetooth in v1 |
| hvc6 | GNSS (`/dev/gnss0`) | `.silent` | location is post-v1 (possible CoreLocation substitute as `.service`) |
| hvc7 | location (`/dev/gnss1`) | `.silent` | |
| hvc8 | confirmationui | `.silent` | |
| hvc9 | UWB | `.silent` | |
| hvc10 | oemlock | `.silent` | |
| hvc11 | KeyMint (Rust, remote `secure_env`) | `.silent` | replaced by in-guest KeyMint |
| hvc12 | NFC | `.silent` | |
| hvc13 | Weaver | `.silent` | #095 checks that LockSettings does not wait for Weaver |
| hvc14 | MCU control | `.silent` | |
| hvc15 | MCU UART | `.silent` | |
| hvc16 | Ti50 TPM | `.silent` | |
| hvc17 | JCardSim | `.silent` | |
| hvc18 | sensors control | `.silent` | no sensors in v1 |
| hvc19 | sensors data | `.silent` | |

`.silent` ports are attached (so the device node exists and opens succeed) but the host never writes. A HAL that blocks reading a silent port just waits; a HAL that times out and crash-loops is recorded in #095 and handled in §7.6.

If VZ turns out to limit the number of serial port devices below 20, the fallback is: attach ports 0–N in order, and the custom image (§11) points the affected HALs elsewhere or disables them.

### 7.2 Security HALs (KeyMint, Gatekeeper)

KeyMint is boot-critical: vold needs it for metadata encryption and file-based encryption keys, so a missing KeyMint stops boot. Gatekeeper is needed for the lock screen and synthetic passwords.

- Cuttlefish ships several vendor APEX variants and selects one with `androidboot.vendor.apex.<apex name>=<variant>` in bootconfig (driven by `launch_cvd --secure_hals`).
- APKRun selects the **in-guest non-secure variants** (the ones `--secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure` selects). The exact APEX names are copied from the reference capture of that profile (§8).
- Consequence: keys are software-backed inside the guest. Attestation reports a software security level and an unlocked device. This is acceptable for v1 (APKRun does not claim hardware-backed keys; [../01-architecture/security-model.md](../01-architecture/security-model.md)). A host-side KeyMint substitute on hvc11 is a post-v1 option.

### 7.3 vsock services

| Service | Cuttlefish | APKRun |
|---|---|---|
| ADB | adbd listens on `vsock:5555` (because `persist.adb.tcp.port=5555`) and `tcp:5555`. The host's `socket_vsock_proxy` bridges host TCP 6520 → guest vsock 5555. | `VsockLoopbackForwarder` bridges `127.0.0.1:6520` → guest vsock 5555 (#015, [vm.md](vm.md) §8) in developer mode. Never bound to non-loopback addresses. On the stock image adbd always runs, and only the forwarder depends on developer mode. On custom images adbd itself runs only in developer mode (§11.3). |
| Guest `socket_vsock_proxy` 6520 → tcp 5555 | started by `init.vendor.rc` | left running; unused |
| Guest → host services (tombstone transmit, modem simulator, camera, audio control, …) | configured by `androidboot.vsock_*` and `modem_simulator_ports` keys | keys omitted, so the clients are not configured. #095 records the behaviour of each client when its key is absent. |
| APKRun agents | — | vsock 6100–6111 via `apkrun_vsockd` on custom images ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3) |
| Reserved for substitutes | — | vsock 6120–6199. v1 is host-initiated only. A substitute that needs guest-initiated connections requires vsock listeners in `VMDefinition` and an ADR. |

### 7.4 Network

Cuttlefish attaches several NICs (mobile, ethernet, Wi-Fi backends), and guest scripts rename interfaces and set up `virt_wifi` on top of one of them, chosen by `androidboot.wifi_impl`. APKRun starts with one NAT NIC ([vm.md](vm.md) §7).

#095 establishes connectivity in this order and stops at the first option that works:

1. **Single NIC as Wi-Fi.** One NAT NIC, with bootconfig and properties arranged so the guest puts `virt_wifi` on it (apps see an unmetered Wi-Fi network, which is best for compatibility).
2. **Cuttlefish NIC order.** Several NAT NICs in Cuttlefish's order so the stock scripts find what they expect. This changes `VMDefinition.network` from one optional NIC to an ordered list (a small VirtualMachineCore change, noted in [vm.md](vm.md) §7).
3. **Ethernet.** Custom image only: add the ethernet feature and let `EthernetManager` run DHCP on `eth0`.

Checks (T2): `ip addr`, a default route, DNS resolution, `generate_204` from inside Android, and `dumpsys connectivity` showing a validated network.

### 7.5 Audio

- Cuttlefish passes virtio-snd to the guest. The guest uses the AIDL audio HAL with `ro.hardware.audio.primary=goldfish` on a tinyalsa card/device.
- APKRun attaches `VZVirtioSoundDeviceConfiguration` ([vm.md](vm.md) §11).
- #083 verifies: `virtio_snd` is loaded (`lsmod`, or built in), `/proc/asound/cards` shows the card, a test tone from HelloAudio (or `tinyplay`) is heard on the host, and the negotiated rate/format is logged. If the module is missing from the stock image, the custom image adds it (§11).
- Microphone input: [vm.md](vm.md) §11 and #084.

### 7.6 Other guest expectations

| Area | Stock behaviour expected without host services | v1 handling |
|---|---|---|
| Input (vhost-user virtio-input from `cf_vhost_user_input`) | no touchscreen/keyboard devices from Cuttlefish | Not reproducible on VZ. Input goes through the Guest Agent ([input.md](input.md), ADR-0013). The USB keyboard/pointer are not attached to the Android VM. |
| Telephony (RIL ↔ `modem_simulator`) | no service; RIL retries | Accept for stock. The custom image disables the RIL only if #095 measures crash-loops or CPU/log cost. |
| Bluetooth, NFC, UWB, GNSS | HALs fail to reach the host | same rule |
| Sensors | no sensors | same rule |
| Camera | none | post-v1 |
| Battery, health, thermal | Cuttlefish HALs report fixed values (charging, full) | keep |
| RTC | PL031 exists on VZ; the GKI driver must be present | #012 checks `/dev/rtc0`. Time sync is also done by the Guest Agent ([desktop-integration.md](desktop-integration.md) §9). |
| Power button (PL061 + gpio-keys) | VZ `requestStop` presses it; Android treats it as a screen-off key | shutdown goes through the Guest Agent ([vm.md](vm.md) §9.3) |

### 7.7 Boot phase markers

The Cuttlefish guest writes status lines to the kernel log, which reaches hvc0: `VIRTUAL_DEVICE_BOOT_STARTED`, `VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`, and others. RuntimeCore's `BootPhaseDetector` uses them as boot-phase signals alongside `sys.boot_completed` read over ADB (M1) or reported by the Guest Agent (M3+) ([runtime-daemon.md](runtime-daemon.md)). #064 confirms the exact strings and their timing.

---

## 8. Reference boot capture (#064)

The reference boot is ground truth for everything that U-Boot and the Cuttlefish launcher normally do. Every VZ boot difference must be explained.

### 8.1 Reference host

In order of preference:

1. An arm64 Linux VM with nested virtualization on an M3-or-later Mac (`VZGenericPlatformConfiguration.isNestedVirtualizationEnabled`, macOS 15+). `/dev/kvm` works inside it, so crosvm runs Cuttlefish at near-native speed.
2. An arm64 Linux machine (bare metal or cloud).
3. An x86-64 Linux host running the arm64 image under QEMU TCG. It is slow, but acceptable for a one-time capture.

The reference host installs the Cuttlefish host tools (`cvd`, from the android-cuttlefish packages for arm64) and the same image build (§2).

### 8.2 Profiles

| Profile | `launch_cvd` flags | Purpose |
|---|---|---|
| `default` | defaults, `--cpus 4 --memory_mb 4096` | how stock Cuttlefish really boots |
| `target` | `--gpu_mode=drm_virgl --secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure --cpus 4 --memory_mb 4096` | the configuration APKRun reproduces on VZ |
| `swiftshader` | `--gpu_mode=guest_swiftshader` + the `target` HAL flags | the fallback GPU profile ([graphics.md](graphics.md) §9) |

If the reference host cannot run `drm_virgl` (it needs host virglrenderer with EGL; Mesa llvmpipe may be enough), the `target` capture is taken with `guest_swiftshader`, and the graphics props for `drm_virgl` come from the Cuttlefish source (`bootconfig_args.cpp`) instead.

### 8.3 What is captured

`Images/tools/reference/capture.sh <profile>` writes `Images/reference/<buildId>/<profile>/`:

| Host side | Guest side (via `adb`) |
|---|---|
| crosvm command line (from `launcher.log` / `ps -ww`) | `/proc/cmdline`, `/proc/bootconfig` |
| `cuttlefish_runtime/instances/cvd-1/internal/bootconfig` (AVB footer stripped) | `getprop` (all) |
| composite disk specs (`os_composite`, persistent composite) | `ls -l /dev/block/by-name/`, `readlink -f /sys/block/vd*`, `lsblk` equivalent from sysfs |
| `cuttlefish_config.json` | `/proc/mounts`, `/vendor/etc/fstab.*` |
| `kernel.log`, `launcher.log` | `dmesg`, `lsmod`, first-stage init log lines |
| | `ls -l /dev/hvc*` and which process holds each (`/proc/*/fd`) |
| | `logcat -d -b all` (gzip), `lshal`, `service list`, `ls /apex`, `pm list features` |
| | `ip addr`, `ip route`, `ip link`, `dumpsys connectivity` summary |
| | `/proc/asound/cards`, `getenforce`, AVC denials |
| | `VIRTUAL_DEVICE_*` markers with timestamps |

Serial numbers, MAC addresses, and host paths are normalized by `normalize.yaml` before committing. The captures contain no secrets.

### 8.4 Diff against the VZ boot

`compare_boot.py <reference dir> <vz capture dir>` runs the same guest-side capture against the VZ boot (through the hvc1 serial shell in M1, because ADB arrives in #015; the Guest Agent later), normalizes both, and writes a report by category (cmdline, bootconfig, props, block devices, mounts, modules, HALs, hvc users, network, SELinux).

Every difference must be listed in `Images/reference/<buildId>/expected-differences.yaml` with a reason (for example "slot_suffix: no U-Boot, fixed `_a`"). An unexplained difference fails the T3 check that belongs to gate G2. This is the verification in [ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md).

---

## 9. Translation to VMDefinition

### 9.1 ImageCore API

```swift
public struct ImageVersion: Comparable, Codable, Sendable, CustomStringConvertible {
    public var year: Int, month: Int, sequence: Int   // ordering uses these only
    public var base: String                           // "cf16373615", "ar000123" (informational)
    public var architecture: String                   // "arm64"
}

public struct InstalledImage: Sendable {
    public var version: ImageVersion
    public var root: URL                              // Images/<version>/
    public var manifest: RuntimeImageManifest         // 03-reference/runtime-image-manifest.md
}

public actor ImageStore {
    public init(paths: APKRunPaths, trust: ImageTrustStore, diagnostics: Diagnostics)
    public var state: RuntimeImageState { get }       // state-machines.md §7
    public func current() throws -> InstalledImage
    public func previous() -> InstalledImage?
    public func install(from source: ImageSource) async throws -> InstalledImage   // .directory(URL) (dev) | .archive(URL) (#058; feed checks #087)
    public func verify(_ image: InstalledImage, depth: VerificationDepth) async throws  // .quick | .full
    public func setCurrent(_ version: ImageVersion) async throws                   // moves `previous`
    public func garbageCollect() async throws                                      // keeps current + previous
}

public actor InstanceStore {
    public func load() throws -> InstanceConfiguration?
    public func provision(image: InstalledImage, sizing: InstanceSizing) async throws -> InstanceConfiguration  // §5.1
    public func resetAndroid(image: InstalledImage) async throws                   // recreate disks from templates
    public func createRecoveryPoint(reason: RecoveryReason) async throws -> RecoveryPoint
    public func restore(_ point: RecoveryPoint) async throws
    public func recoveryPoints() -> [RecoveryPoint]
}

public struct AndroidBootPlanner: Sendable {
    public init(platform: VZPlatformProfile)
    /// Regenerates Runtime/instance/boot/initrd.img and returns the Android parts of the definition.
    public func prepareBoot(image: InstalledImage,
                            instance: InstanceConfiguration,
                            options: BootOptions) throws -> AndroidBootPlan
}

public struct BootOptions: Sendable {
    public var gpuProfile: GPUProfileID                // .drmVirgl (default) | .guestSwiftshader | .headless (dev only)
    public var developerMode: Bool
    public var captureLogcat: Bool
    public var soundOutput: Bool
    public var microphone: Bool
}

public struct AndroidBootPlan: Sendable {
    public var definition: VMDefinition               // customDevices empty; RuntimeCore adds the GPU device
    public var bootconfig: [BootconfigEntry]          // merged, with layer of origin (diagnostics)
    public var bootRecordID: UUID
}
```

`ImageSource`, `InstanceConfiguration`, `InstanceSizing`, `RecoveryPoint`, and `VZPlatformProfile` are plain `Codable` values defined next to these types.

`GPUProfileID.headless` is for bring-up only (#012–#017, `apkrun dev boot --gpu none`). Its layer-2 keys are Cuttlefish's no-GPU graphics set, copied in #014 from `bootconfig_args.cpp` at the revision of the pinned build. Only development bundles list it in `gpuProfiles`, and `bundle` refuses to write it into a release-signed bundle ([graphics.md](graphics.md) §9; [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.7, §7.3).

### 9.2 Field mapping

| `VMDefinition` field | Source |
|---|---|
| `label` | `"APKRun Android (" + imageVersion + ")"` |
| `cpuCount`, `memorySize` | `instance.json` sizing, which RuntimeCore refreshes from the settings `runtime.cpuCount` and `runtime.memoryGiB` before each boot ([vm.md](vm.md) §10) |
| `machineIdentifier` | `instance.json` |
| `boot` | `.linux(kernel:initialRamdisk:commandLine:)`. `kernel` is `Images/<v>/` + manifest `boot.kernel.path`. `initialRamdisk` is `Runtime/instance/boot/initrd.img`, built from `boot.ramdisk` and the merged bootconfig (§6.3). `commandLine` is the contents of the `boot.cmdline` file |
| `disks` | manifest `disks`, then `templates`, each in array order (§4.2). The `os` disk is `Images/<v>/` + its `path`, read-only, with caching `.automatic`. Each template is its instance clone `Runtime/instance/<file name of path>`, read-write, with synchronization `.full`. `readOnly`, `identifier`, and `role` come from the manifest entry ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.5) |
| `network` | `.nat(macAddress:)` from `instance.json` (§7.4 may make this a list) |
| `vsockEnabled` | `true` |
| `consolePorts` | manifest `consolePorts` (§7.1), roles adjusted by `BootOptions` (logcat capture, developer mode), then ordered by `ConsolePortPlan` ([vm.md](vm.md) §6.2) |
| `entropy`, `memoryBalloon` | `true`, `true` |
| `sound` | `SoundDefinition(output: options.soundOutput, input: options.microphone)` |
| `customDevices` | empty here. RuntimeCore appends the virtio-gpu device from GraphicsCore ([graphics.md](graphics.md)). ImageCore cannot depend on GraphicsCore ([../01-architecture/modules.md](../01-architecture/modules.md) §3). |

### 9.3 Before every boot

1. `ImageStore.verify(current, .quick)`: steps 1–7 of [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.1 (signature, `schemaVersion`, schema, semantic rules, the file set, and file sizes). The result of steps 1–6 is cached for the life of the apkrund process, keyed by the inode, size, and modification time of `manifest.json`. The full hash check (step 8) runs at install and in `apkrun doctor --deep`.
2. `InstanceStore.load()`: disks present, sizes as recorded, `imageVersion` equals `current` (otherwise a migration is pending, §12.3).
3. Compatibility: `manifest.requirements.minimumRuntimeVersion ≤ APKRun version`, and the guest protocol range intersects the host's `guestProtocol.majors` in `components.json` ([runtime-maintenance.md](runtime-maintenance.md) §2.1). Failures: `incompatibleRuntime(required)`, `incompatibleProtocol(range)` (§12.1, §14.1).
4. `AndroidBootPlanner.prepareBoot` writes the initrd and returns the plan.
5. RuntimeCore adds the GPU device and hands the definition to `VMController`.

---

## 10. Runtime image bundle (#065)

### 10.1 Contents

The layout on disk is defined in [../01-architecture/filesystem-layout.md](../01-architecture/filesystem-layout.md) §1 (`Images/<imageVersion>/`). The full manifest schema is in [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md). In summary, `manifest.json` has:

| Block | Content |
|---|---|
| `schemaVersion`, `imageVersion`, `kind` | `kind` = `stock` (from a ci.android.com build; development only) or `apkrun` (our product) |
| `provenance` | the `source` and `android` blocks of the AndroidImageManifest, `deviceFamily`, the layout file and its SHA-256, the reference capture used, tool versions, the git revisions of `Images/tools` and `Guest/`, and, for `apkrun` only, `pinnedManifestSHA256` and `builderImageDigest` (§11.5) |
| `guest` | `sdk`, `abis`, `targetSdkFloor`: guest facts for package checks before the first boot ([package-store.md](package-store.md) §4.6) |
| `boot` | `kernel`, `ramdisk`, `bootconfig`, `cmdline` file entries (path, size, SHA-256), `kernelPageSize`, `bootconfigOverrides` (§6.1) |
| `disks` | exactly one entry, `os.img`: role, path, `readOnly`, identifier, logical size, partitions (label, first LBA, size, SHA-256 of contents) |
| `templates` | `persistent.img`, then `userdata.img`: the same fields. The `userdata` entry also has `userdataStrategy` (`blankFormattable` / `prebuiltTemplate`, §5.2) |
| `consolePorts` | 20 entries: index, role, name (§7.1) |
| `gpuProfiles` | `drmVirgl`, `guestSwiftshader`, and in development bundles `headless` (§9.1): bootconfig fragments, the keys each may override, and required host capabilities |
| `requirements` | `minimumRuntimeVersion` (APKRun host version), `guestProtocol` (min/max), agents (package, versionCode) built into the image. Empty for `stock` |
| `userdata` | `schemaVersion`, `upgradableFrom` (list of schema versions this image can boot with) |
| `compatibility` | `upgradeFrom.minimumImageVersion`: the oldest current image that may migrate to this one (C4 in [runtime-maintenance.md](runtime-maintenance.md) §4.2) |
| `legal` | optional: the `notice` file entry (`legal/notice.html`, license notices and source offers). Required in bundles published on a feed |
| `files` | every file with size and SHA-256 (the same data as `SHA256SUMS`), except `manifest.json`, `manifest.sig`, and `SHA256SUMS` |

Unknown fields are rejected at every level.

`manifest.sig` is an Ed25519 signature over the exact bytes of `manifest.json`, with a key ID in a small, unsigned header. The key ID is the first 8 bytes of SHA-256 over the raw public key, in hex. `ImageTrustStore` is a list of (key ID, public key) pairs compiled into the app. Release builds contain the release keys only. Debug builds, and the `ReleaseUpdateTest` builds of the maintenance tests ([../05-development/build-system.md](../05-development/build-system.md) §2.4), also contain the per-developer key created by `python3 -m apkrun_image keygen` (`~/.config/apkrun/dev-image-key.pub`, never committed). Each lab Mac creates its own key the same way and signs the CI test bundles with it ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §3.5). Tests inject a store with `test-image-ed25519`. An unknown key ID is `untrustedKey(keyID)`, and a signature that does not verify is `signatureInvalid(keyID)`. The format is in [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §6.1. `SHA256SUMS` duplicates `files` so that `shasum -a 256 -c` works in a shell. It is not signed, so ImageCore only checks that it matches `files`.

Verification order ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.1): signature → `schemaVersion` and manifest schema → semantic rules S1–S14 → the exact file set and every file's size → (full verification only) every file's hash. ImageCore rejects extra files not listed in `files`.

Manifest `schemaVersion`: installed manifests are signed, so they are never rewritten or migrated. ImageCore keeps a decoder for every manifest schema version from 1 up to the newest it knows, and reads an older manifest with its own version's rules. A newer version fails with `manifestInvalid` ("needs a newer APKRun"). The release rule that an image sets `minimumRuntimeVersion` to an APKRun that reads its schema keeps this from reaching users ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §11). Host data files such as `instance.json` are different: they are migrated ([runtime-maintenance.md](runtime-maintenance.md) §5).

### 10.2 Build command

```bash
python3 -m apkrun_image bundle \
  --manifest Images/manifests/16373615/android-image.json \
  --layout   Images/tools/layouts/cuttlefish-phone-arm64.json \
  --reference Images/reference/16373615/target \
  --image-version 2026.10.0 \
  --sign-key ~/.config/apkrun/dev-image-key \
  --out Images/work/16373615/bundle/
```

It runs extract (§4.1), disks (§4.5), and the bootconfig baseline (§6), writes `boot/bootconfig.txt` (the `[vendor]` section from `vendor-bootconfig.txt`, the `[image]` section from the layout and the `avb.py` values), then writes the manifest, `SHA256SUMS`, and the signature. The version string gets the base suffix (`-cf16373615-arm64`) automatically. The naming rules are in [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md).

- **Deterministic:** the same inputs and tool revision produce identical bytes (fixed GUIDs, no timestamps, sorted keys). CI builds the fixture bundle twice and compares `SHA256SUMS` (T1).
- **Size:** `os.img` is written sparse. Physical size is about the sum of the images (super ≈ 1.75 GB of data for build 16373615).
- **Unsigned development bundles (#012 until #065):** `bundle --unsigned` writes the same tree without the two signature files. Only a Debug build loads it, through `DevelopmentImage.load(directory:)`, and `apkrun dev boot --bundle <dir>` boots it in place without installing it ([cli.md](cli.md) §5). #065 adds signing and installation (§10.3) and removes `--unsigned`, `DevelopmentImage`, and `--bundle`.

### 10.3 Development install

`apkrun dev image install Images/work/16373615/bundle/` asks apkrund (or the embedded runtime before #031) to install the directory. ImageCore verifies it, `clonefile`s the files into `Images/.installing-<version>/`, renames the directory to `Images/<version>/`, and sets `current`. If there is no instance yet, it provisions one (§5.1). Acceptance of #065: a bundle built from the stock image boots to `sys.boot_completed=1` under VZ.

### 10.4 Release packaging and distribution (#087)

- **Archive:** the release pipeline (on macOS) packs the directory of a release-signed bundle with `aa archive -a lzfse` into `<imageVersion>.aar`, with entries relative to the bundle root. Runs of zeros compress to almost nothing. Format: [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.1.
- **Feed:** a signed JSON index per channel (`stable`, `beta`) lists versions, archive URL, archive size and SHA-256, requirements, userdata compatibility, rollout, and release notes, with a sequence number and an expiry against replay. The format is in [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §9, and the client rules are in [runtime-maintenance.md](runtime-maintenance.md) §4.1. The hosting location depends on OQ-01 (domain). `feed.json.sig` uses the same signature format and `ImageTrustStore` as `manifest.sig`.
- **Download:** resumable (`Range`) into `Cache/images/`, with free-space checks before downloading and before installing (archive size + `expandedSize` + 10 GiB margin; [runtime-maintenance.md](runtime-maintenance.md) §4.4).
- **Install** (steps in [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.3): the archive SHA-256 is checked against the feed entry (a manual install from a file has no feed entry and skips this). The archive is extracted with the AppleArchive framework into `Images/.installing-<name>/` (`<name>` is the `imageVersion`, or `manual-` + 16 random hex digits for a manual install) under the entry rules of [runtime-maintenance.md](runtime-maintenance.md) §4.5 (regular files and directories only, no path escapes). The result gets full verification (§10.1), and for a feed install the manifest must agree with the feed entry. ImageCore then punches holes in the files under `disks/` and `templates/` (`fcntl(F_PUNCHHOLE)` over all-zero 1 MiB blocks) so the installed image is sparse again. Finally the directory is renamed to `Images/<imageVersion>/` and the archive is deleted. An install changes neither `current` nor `previous`. An interrupted install leaves only `.installing-*`, which is deleted at startup.
- **UX:** "Android system update ready". It is applied when the Mac is idle (the apply gate) or when the user clicks, never while sessions are active unless the user agrees ([runtime-maintenance.md](runtime-maintenance.md) §4.6, §7).

---

## 11. APKRun AOSP product (#035, M5)

The agents themselves are designed in [guest-components.md](guest-components.md). This section covers the image build.

### 11.1 Product definition

The source lives in `Guest/product/` and is mapped into the AOSP tree as `device/apkrun/apkrun_arm64/` (a `repo` local manifest entry pointing at this repository).

```text
Guest/product/
├── AndroidProducts.mk        # PRODUCT_MAKEFILES := $(LOCAL_DIR)/apkrun_arm64.mk
│                             # COMMON_LUNCH_CHOICES := apkrun_arm64-trunk_staging-userdebug apkrun_arm64-trunk_staging-user
├── apkrun_arm64.mk           # $(call inherit-product, device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk)
│                             # PRODUCT_NAME := apkrun_arm64, PRODUCT_DEVICE stays vsoc_arm64_only
│                             # PRODUCT_PACKAGES += apkrun_vsockd ApkRunGuest ApkRunStore
│                             # BOARD_SEPOLICY_DIRS += device/apkrun/apkrun_arm64/sepolicy
├── Android.bp                # android_app_import for the agent APKs in prebuilt/ (certificate: "platform", privileged: true,
│                             # presigned: false; installed in /system_ext/priv-app), prebuilt_etc for permissions/init.
│                             # apkrun_vsockd is a rust_binary in its own Guest/vsockd/Android.bp (build-system.md §9)
├── prebuilt/                 # git-ignored: the two agent APKs, copied here by scripts/build-guest.sh
├── init/apkrun.rc            # apkrun_vsockd service, devmode property triggers
├── sepolicy/                 # apkrun_vsockd.te (typeattribute … unconstrained_vsock_violators),
│                             # apkrun_guest_app.te, apkrun_store_app.te, file_contexts, seapp_contexts
├── permissions/              # privapp-permissions-apkrun.xml, default-permissions, feature XMLs
├── overlay/                  # framework config overlays (multi-display, IME, freeform)
├── settings/                 # default Settings.Global values (e.g. enable_freeform_support, force_resizable_activities)
└── manifest/pinned.xml       # `repo manifest -r` snapshot of the AOSP checkout used for release builds
```

The policy starts in `BOARD_SEPOLICY_DIRS`. If the Treble `neverallow` checks reject types for `/system_ext` files there, #035 moves those rules to `SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS` and records the split here ([../04-plan/issues/M05-custom-android-image.md](../04-plan/issues/M05-custom-android-image.md) #035).

Notes:

- The base product sets `PRODUCT_IGNORE_ALL_ANDROIDMK := true`, so all modules use `Android.bp`.
- The base product uses a 16K maximum page size. Our Rust and Kotlin components have no page-size assumptions.
- `vendor/google` is not needed. The desktop product (`aosp_cf_x86_64_desktop`) is x86-only and not used.
- Properties: `ro.apkrun.product=1`, plus the GPU props of the default profile. The image version is not a build property: it is assigned later, by `bundle --image-version`, so ImageCore passes it at every boot as `androidboot.apkrun.image` (§6.2), which Android exposes as `ro.boot.apkrun.image`.

### 11.2 What the product changes, and what it does not

| Change | Why |
|---|---|
| Adds the Guest Agent, Store Agent, `apkrun_vsockd`, and their sepolicy and privapp permissions | production control path ([ADR-0008](../01-architecture/decisions/0008-guest-agents.md)) |
| Defaults the KeyMint/Gatekeeper APEX selection to the in-guest variants | §7.2; bootconfig still sets them explicitly |
| Adds `virtio_snd` if the stock kernel modules lack it | §7.5 |
| Sets `Settings.Global.AUTO_TIME = 0` and `AUTO_TIME_ZONE = 0` (settings provider overlay) | the host is the only time source ([desktop-integration.md](desktop-integration.md) §9) |
| Includes an in-Android browser (AOSP `Browser2`) if the base product has none | "Keep in Android" for links ([desktop-integration.md](desktop-integration.md) §7.1, *verify* in #081) |
| Adds features/overlays for multiple displays and freeform where needed | [display-and-windowing.md](display-and-windowing.md) |
| Disables specific HALs/services only with evidence from #095 (crash loops, boot delay, CPU or log flood) | "Do not aggressively remove services" (#035) |
| Does **not** change the kernel, partition layout, or fstab | keeps us close to Cuttlefish, so the stock image stays a valid development target |

### 11.3 Developer mode on custom images

- `androidboot.apkrun.devmode=1` (instance layer, §6.2) makes `init/apkrun.rc` start adbd listening on vsock 5555 (triggered by `ro.boot.apkrun.devmode`). With `0`, the default, adbd does not run, even in a userdebug build whose base product would start it: `apkrun.rc` stops it on `property:ro.boot.apkrun.devmode=0`. *Verify* in #035 that no other trigger restarts it (`pidof adbd` over the serial console). Changing the setting takes effect at the next runtime start, like the microphone setting.
- `user` builds have `ro.adb.secure=1`. The Guest Agent authorizes the host's ADB key with `AdbManager.allowDebugging` (needs `MANAGE_DEBUGGING`) so no dialog appears on a display the user cannot see. Details are in [guest-components.md](guest-components.md).

### 11.4 Variants and verified boot

| Build | Variant | Use | AVB state passed |
|---|---|---|---|
| Development | `apkrun_arm64-trunk_staging-userdebug` | M5 onward, CI | `orange` / unlocked |
| Release | `apkrun_arm64-trunk_staging-user` signed with our release keys | shipped images | decided in #035; proposed below |

Proposed for release, and to be confirmed in #035: pass `orange`/`unlocked`, but keep dm-verity on through the vbmeta hashtree descriptors. Without a bootloader the guest cannot establish a hardware root of trust anyway. The integrity chain is host-side: signed manifest → file hashes → `os.img` attached read-only. The alternative (claim `green` with a locked state) would misrepresent the device state to apps and attestation.

### 11.5 Build

- Host: x86-64 Linux, ≥ 64 GB RAM, ≥ 400 GB disk ([../05-development/environment-setup.md](../05-development/environment-setup.md) §5). macOS cannot build AOSP.
- Steps: `repo init` with the pinned manifest → `repo sync` → `source build/envsetup.sh` → `lunch apkrun_arm64-trunk_staging-userdebug` → `m` → `m dist DIST_DIR=out/dist`, with `BUILD_NUMBER=ar<counter>` (`scripts/aosp/build-product.sh`, [../05-development/environment-setup.md](../05-development/environment-setup.md) §5.4). The resulting `*-img-*.zip` goes through the same pipeline as the stock image (§3–§10), starting with inventory.
- Reproducibility: the pinned manifest, the builder container image digest, and the Guest/ git revision are recorded in the bundle's `provenance`.
- Acceptance of #035: the custom image reaches `boot_completed` under APKRun, the agents start, and the reference diff (§8.4) has no unexplained differences beyond the documented product changes.

---

## 12. Versioning, compatibility, and migration (#058, #087)

### 12.1 Versions and compatibility

- `imageVersion` = `YYYY.MM.N-<base>-<arch>`, compared on (YYYY, MM, N) only. Versions are monotonic. APKRun never installs a lower version automatically.
- `requirements.minimumRuntimeVersion`: the oldest APKRun host version that may boot the image. If the host is older, the image is not offered (feed) or not activated (manual install), and the user is told to update APKRun.
- `requirements.guestProtocol`: the guest agents' protocol range. It must intersect the host's range ([guest-protocol.md](guest-protocol.md)).
- `userdata.schemaVersion`: APKRun's integer for "what the data on `/data` and `/metadata` looks like to APKRun" (Android major version, agent data layout). An image lists the schema versions it can boot with in `userdata.upgradableFrom`. Android upgrades `/data` forward on first boot of a newer release but cannot go back, so moving to an image whose schema is lower than the instance's is refused unless the user chooses "Reset Android".

### 12.2 Recovery points

`InstanceStore.createRecoveryPoint` writes `Runtime/instance/recovery-points/<timestamp>-<imageVersion>/` with `clonefile` copies of `persistent.img`, `userdata.img`, and `instance.json`. The VM must be stopped. Clones are instant and share blocks, so the cost is the blocks changed afterwards. After a successful migration, only the most recent recovery point is kept.

### 12.3 Migration A → B

ImageCore provides the data steps. RuntimeCore's `RuntimeSupervisor` orchestrates the boot and health check, because ImageCore never starts VMs.

```text
preconditions  B installed and fully verified; A → B allowed (compatibility, userdata schema);
               no active sessions, or the user agreed; free space ≥ 10 GiB
1. stop VM gracefully (vm.md §9.3)
2. ImageCore: recovery point R of the instance (image A)
3. ImageCore: instance.json `migration` ← (A, B), which is `RuntimeImageState.migrating(A, B)`; then `previous` → A, `current` → B;
   instance.json imageVersion ← B
4. RuntimeCore: boot B with the existing persistent/userdata (first-boot timeout 15 min: package scan and dexopt)
5. RuntimeCore: health check
     - sys.boot_completed = 1
     - Guest Agent and Store Agent handshakes succeed, protocol in range
     - every package in the host PackageStore is present with the recorded versionCode
     - a display can be created and a frame from the Guest Agent's health activity arrives
6a. success: instance.json `migration` removed (`installed(B)`); prune recovery points except R; garbage-collect images (runtime-maintenance.md §4.9)
6b. failure (timeout, crash loop, failed check):
     stop VM; move the failed disks to recovery-points/failed-<ts>/ for diagnostics (deleted after 7 days);
     restore R (clonefile back); `current` → A; last, R's instance.json with a new `userdataGeneration` (§5.1)
     and no `migration` (`installed(A)`); B is rejected by the caller (not retried automatically,
     runtime-maintenance.md §4.8);
     offer a diagnostics bundle
```

Crash safety: the migration state lives in the `migration` field of `Runtime/instance/instance.json`, which ImageCore's `InstanceStore` owns. It is written before step 3 changes anything and removed only by the last write of 6a or 6b. Every write of `instance.json` goes to a temporary file, is `fsync`ed, and is renamed into place, and the `current` and `previous` symlinks are replaced the same way. If apkrund starts and finds a `migration` field with no VM running, it treats the migration as failed and runs 6b, because the health result is unknown. 6b can run again after a crash in 6b: it always restores R from the start.

Errors (§14.1): a failed precondition is `incompatibleRuntime`, `incompatibleProtocol`, `userdataSchemaUnsupported`, `migrationSourceTooOld`, `downgradeRejected`, or `insufficientSpace`. A failed health check (6b) is `migrationHealthFailed(report)`, and a migration found at startup is `migrationInterrupted`. For an Android system update, the user sees them as the cause of `maintenance.imageMigrationFailed` ([../03-reference/error-catalog.md](../03-reference/error-catalog.md) §9, §14.2).

Manual rollback after a successful migration ("Go back to the previous Android version") restores R, and therefore loses data written since the migration. The UI says so and requires confirmation.

### 12.4 Acceptance of #058

T2 test with two bundles built from the same base: A, and B = A with `androidboot.apkrun.test.marker=B` in its bootconfig and a higher version. The guest reads the marker as `ro.boot.apkrun.test.marker`, because bootconfig sets only `ro.boot.*` properties.

1. Provision with A, install HelloText, increment its persistent counter.
2. Migrate to B. Expect `installed(B)`, `ro.boot.apkrun.test.marker` is `B`, HelloText is present, and its counter value is preserved.
3. Build B′ with a deliberate health failure (`androidboot.apkrun.test.fail_health=1`, which makes the Guest Agent report unhealthy; Android itself boots). Migrate B → B′. Expect `installed(B)` after the automatic restore, B′ marked rejected, and HelloText data intact.

---

## 13. Deviations from standard Cuttlefish

#013 requires documenting every deviation. This table is the summary. Its IDs use the prefix `CF-` to identify Cuttlefish-specific differences. `Images/reference/<buildId>/expected-differences.yaml` is the detailed, machine-checked list (§8.4).

| # | Deviation | Reason | Section |
|---|---|---|---|
| CF-01 | No U-Boot. Direct kernel boot with a pre-assembled initrd and bootconfig | VZ boot loaders; ADR-0015 | §4.1, §6 |
| CF-02 | Slot `_a` only, no `_b` partitions | no OTA | §4.2 |
| CF-03 | No `uboot_env`, persistent vbmeta, or `bootconfig` partitions | U-Boot only | §4.2 |
| CF-04 | Raw GPT disk images instead of crosvm composite disks | VZ attaches files | §4.2 |
| CF-05 | `boot_devices` is the VZ PCI host (not `10000.pci`) | platform difference | §5.3 |
| CF-06 | Blank userdata formatted at first boot | clean instances; no host-side f2fs tools on macOS | §5.2 |
| CF-07 | In-guest non-secure KeyMint and Gatekeeper | no `secure_env` host process | §7.2 |
| CF-08 | Most hvc ports are silent sinks | no host services | §7.1 |
| CF-09 | No vhost-user input devices; input through the Guest Agent | not reproducible on VZ | §7.6 |
| CF-10 | virtio-gpu is APKRun's custom virtio device (VirGL) instead of crosvm's | VZ custom virtio API | [graphics.md](graphics.md) |
| CF-11 | Network: VZ NAT (one NIC initially) | VZ | §7.4 |
| CF-12 | No modem simulator, rootcanal, GNSS, sensors, camera hosts | out of v1 scope | §7.6 |

New rows are added whenever #011–#014, #035, #083, or #095 find a difference. #035 adds the product changes of §11.2 that differ from Cuttlefish at runtime (for example the developer-mode gate of adbd, §11.3).

---

## 14. Errors, logging, health

### 14.1 `ImageFailure` (error domain `image`)

| Case | When | Remediation shown |
|---|---|---|
| `manifestInvalid(path, reason)` | schema or semantic check failed | reinstall the image |
| `signatureInvalid(keyID)` / `untrustedKey(keyID)` | bad or unknown signature | reinstall from the official feed; in development, trust your dev key |
| `hashMismatch(file)` / `missingFile(file)` / `unexpectedFile(file)` | integrity failure | reinstall the image; run `apkrun doctor --deep` |
| `incompatibleRuntime(required)` | host too old | update APKRun |
| `incompatibleProtocol(range)` | agents' protocol range outside the host's | variant `hostNewer` (the image's range ends below the host's lowest major): update Android. Variant `guestNewer` (it starts above the host's highest major): update APKRun |
| `userdataSchemaUnsupported(instance, image)` | downgrade of userdata schema | choose a newer image or Reset Android |
| `migrationSourceTooOld(minimum)` | the current image is older than the new image's `compatibility.upgradeFrom.minimumImageVersion` (C4 in [runtime-maintenance.md](runtime-maintenance.md) §4.2), at a manual activation. The feed never offers such an image | update Android first, or Reset Android |
| `downgradeRejected(from, to)` | lower version | — |
| `insufficientSpace(required, available)` | install, provisioning, migration | free disk space |
| `cloneUnsupported(volume)` / `cloneFailed(errno)` | not APFS, or `clonefile` failed | move Application Support to APFS (rare) |
| `instanceMissing` / `instanceCorrupt(reason)` | disks or `instance.json` missing or inconsistent | Reset Android (data loss, confirmed) or restore a recovery point |
| `bootconfigConflict(key, layerA, layerB)` / `bootconfigTooLarge(size)` / `cmdlineTooLong(length)` | boot preparation | report a bug (image or app defect) |
| `migrationHealthFailed(report)` / `migrationInterrupted` | §12.3 | automatic restore; diagnostics bundle |
| `recoveryPointMissing` | restore requested without a recovery point | — |
| `developmentImageInUse` | health finding of `image.kind` (§14.3), never thrown | install the standard Android system |
| `recoveryPointStale` | health finding of `image.recoveryPoint` (§14.3), never thrown | Settings → Storage shows the space it uses |

The catalogue with codes and user text is in [../03-reference/error-catalog.md](../03-reference/error-catalog.md).

### 14.2 Logging

Subsystem `io.apkrun.image`, categories `store`, `install`, `verify`, `instance`, `boot`, `migration`. Every boot logs the image version, the bootconfig hash, and the disk identifiers. Bootconfig values are not secret, but `androidboot.serialno` and the instance UUID are redacted in diagnostics bundles ([diagnostics.md](diagnostics.md) §6).

### 14.3 Health checks (`apkrun doctor`)

| Check | Pass condition |
|---|---|
| `image.current` | `current` exists and passes quick verification (`--deep`: full hashes) |
| `image.instance` | instance disks present, sizes as recorded, `imageVersion` consistent |
| `image.freeSpace` | ≥ 10 GiB free on the Application Support volume (warning below) |
| `image.kind` | warning `image.developmentImageInUse` if a `stock` (development) image is the user's runtime |
| `image.recoveryPoint` | at most one recovery point, and none left from a failed migration older than 7 days (warning `image.recoveryPointStale`) |
| `image.migration` | no migration stuck in `migrating` |

---

## 15. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | Python: inventory classification of synthetic files (each magic), manifest schema + semantic checks over valid/invalid fixtures, sparse decoder (all chunk types, CRC), GPT writer/reader round trip, bootconfig serialize/merge/trailer golden vectors, kernel decompression and header checks | #008–#011 |
| T0 | Swift: `ImageVersion` ordering and parsing, `AndroidImageManifest`/`RuntimeImageManifest` decoding over the shared fixtures, bootconfig merge conflicts, trailer golden vectors, GPT backup relocation, `VMDefinition` mapping (§9.2) | #009, #012, #065, #066 |
| T1 | Pipeline end to end on synthetic fixture images (built with the vendored mkbootimg), twice, identical `SHA256SUMS` | #065 |
| T1 | ImageCore install from a directory and from an `.aar`, hole punching, signature rejection, extra-file rejection, interrupted install cleanup, provisioning and `clonefile` on a temporary APFS volume, recovery point create/restore | #065, #066, #058 |
| T2 | Linux test guest sees the three disks with the right partition names and sizes; `/proc/bootconfig` equals the golden trailer; `boot_devices` value discovered | #011, #012 |
| T2 | Stock image: kernel boot (#012), init (#013), `sys.boot_completed=1` and stable for 10 minutes (#014), ADB commands (#015) | #012–#015 |
| T2 | Console port numbering with 20 ports; each hvc role behaves as planned | #095 |
| T2 | Migration A → B, and a failed migration B → B′ that returns to B (§12.4) | #058 |
| T3 | Gate G2: boot_completed + reference diff with no unexplained differences | #014, #064 |

---

## 16. Open items

Risks (R-NN) are in [../04-plan/risks.md](../04-plan/risks.md), open questions (OQ-NN) in [../04-plan/open-questions.md](../04-plan/open-questions.md).

| Item | Plan |
|---|---|
| Sizes of the blank partitions in the manifest (§3.2) | placeholders until #011 reads the real sizes from the reference capture (§8) |
| Ramdisk fragment policy: every non-recovery fragment, in table order (§4.1) | #013 compares the first-stage module list (`lsmod` and the first-stage init log) with the reference capture |
| Partitions left out on VZ: `uboot_env`, `bootconfig`, the persistent vbmeta, `android_esp`, `pvmfw_a`, `vvmtruststore`, `hibernation` (§4.2) | #011 checks each one against the reference `ls -l /dev/block/by-name` and the fstab. A partition that turns out to be required is added blank, and each correction is recorded in §13 |
| Whether a component needs `_b` partitions (§4.2) | #013, #014. If one does, equal-sized zero-filled `_b` partitions are added (holes on APFS) |
| The VZ virtio-blk logical sector size is 512 bytes (§4.4) | #005 and #011 check it with `blockdev --getss` |
| Android formats the blank userdata on first boot: `formattable` on `/data` and `/metadata`, and the metadata encryption path (§5.2) | #011 reads `/vendor/etc/fstab.*` in the reference capture, #013 boots it. If first-boot formatting fails under VZ: fallback A (the zip's `userdata.img`) or fallback B (a `make_f2fs` template), both with a fixed size |
| The `androidboot.boot_devices` value, and whether it is stable across macOS builds (§5.3, R-16) | #011 discovers it, #013 confirms the by-name labels, and the T2 suite re-checks it on every new macOS build. Alternative: `androidboot.boot_part_uuid` with a single-disk layout, not built unless needed |
| Exact values of the "reference" bootconfig keys and the security HAL APEX names (§6.2, §7.2) | copied from the reference capture of the target profile (§8) during #013 |
| Layer-2 keys of the `headless` GPU profile (§9.1) | #014 copies Cuttlefish's no-GPU graphics set from `bootconfig_args.cpp` at the revision of the pinned build |
| The stock image on the VZ topology (R-06) | #012–#014 (gate G2), diffed against the reference capture (#064). Fallback: adapt the custom image (#035): kernel config, fstab, init scripts |
| Direct kernel boot misses something that U-Boot provides (R-11, §6) | #012–#014, with the U-Boot inputs listed by #064. Fallback: a U-Boot EFI build ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)) |
| Cuttlefish host services: 20 console ports, HALs on silent ports, Weaver, vsock clients without their keys (§7.1, §7.3, R-12) | #095, #014. Fallback: attach fewer ports, and the custom image points the affected HALs elsewhere or disables them (§7.1) |
| Network on VZ's single NIC (§7.4, OQ-37) | #095. Working default: option 1, one NIC as `virt_wifi`. Otherwise options 2 and 3 |
| `virtio_snd` in the stock kernel (§7.5, OQ-38) | #083. If it is missing, the custom image adds it |
| RIL, Bluetooth, GNSS, and sensors without host services (§7.6) | accepted on the stock image. The custom image disables a HAL only if #095 measures crash loops or CPU and log cost |
| The PL031 RTC driver (§7.6) | #012 checks `/dev/rtc0` |
| Boot phase marker strings and their timing (§7.7) | #064 confirms them |
| AVB state and dm-verity of the release variant (§11.4, OQ-36) | decided in #035. Proposal: `orange`/`unlocked` with dm-verity on |
| SELinux policy for `apkrun_vsockd` and the agents (R-13) | #035. Fallback: move the function into a system service of the product, or use the platform-signed priv-app path |
| AOSP build infrastructure and release-drop changes (R-14) | #035. The stock image stays usable for development until the custom image passes the same pipeline (§11) |
| Licensing of redistributed images (§2.3, R-10) | #093, before v1.0. Stock Google-built images are for development only |
| Host of the image feed and archives (§10.4, OQ-01) | decided before #087. Working default: a placeholder host in development and a local HTTP server in tests |
| Archive extraction writes the zero runs of `os.img` before holes are punched (§10.4, R-25) | #087 measures the time and the bytes written. Fallback: a sparse-aware extraction sink |

---

## 17. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build, and the result.

| Question | Task | Result |
|---|---|---|
| VZ virtio-blk logical sector size | #005, #011 | pending (§4.4) |
| Kernel compression, ramdisk fragment list, and command-line length of the pinned build | #010 | pending (§4.1) |
| Real sizes of the blank partitions; omitted partitions not needed | #011 | pending (§3.2, §4.2) |
| fstab `formattable` flags and the metadata encryption path | #011 | pending (§5.2) |
| Guest-visible topology and `androidboot.boot_devices` value | #011 | pending (§5.3) |
| Direct kernel boot of the stock image; `/dev/rtc0` present | #012 | pending (§6, §7.6) |
| First-stage modules match the reference; `/dev/block/by-name/` has every label; first-boot userdata formatting | #013 | pending (§4.1, §5.2, §5.3) |
| `sys.boot_completed=1` with the `headless` profile; `_b` partitions not needed | #014 | pending (§4.2, §9.1) |
| AVB state of the release variant; SELinux denials on the custom image | #035 | pending (§11.4, OQ-36, R-13) |
| Reference capture: U-Boot inputs, boot phase markers, diff against the VZ boot | #064 | pending (§7.7, §8) |
| `virtio_snd` in the stock kernel | #083 | pending (OQ-38) |
| Archive extraction time and bytes written | #087 | pending (R-25) |
| 20 console ports, silent-port HAL behaviour, Weaver, vsock clients, RIL cost | #095 | pending (§7.1, §7.3, §7.6) |
| Network on the stock image | #095 | pending (§7.4, OQ-37) |
