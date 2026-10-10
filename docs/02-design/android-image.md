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
  ├─ disk assembly (#011): os.img (GPT) + template (userdata)
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
│   │   ├── sign.py                # Ed25519 manifest signing
│   │   ├── erofs.py               # pinned erofs-utils: EROFS export and PAX rebuild (#099)
│   │   ├── selinux_labels.py      # file-context rule for files a rebuild adds (#099)
│   │   └── vendor_inject.py       # `inject-vendor`: Mesa libraries into vendor_a (#099)
│   ├── layouts/
│   │   └── cuttlefish-phone-arm64.json   # disk plan + console port plan + bootconfig baseline for this device family
│   ├── schemas/
│   │   ├── android-image-manifest.schema.json
│   │   └── runtime-image-manifest.schema.json
│   ├── reference/
│   │   ├── capture.sh             # runs on the Linux reference host (§8)
│   │   ├── capture_cvd_start.py   # bounds CVD commands and snapshots live logs
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
- Downloads resume with HTTP `Range`. Finalization copies the completed partial into a private staging directory, reads no more than the declared size plus one byte, checks its size and SHA-256, makes the staged file read-only, then atomically hard-links it to the final name. An interruption can leave the resumable `.partial` or a complete final artifact, never a truncated file at the final name. It never overwrites an existing artifact. After each download the tool records name, size, and SHA-256 in `Images/work/<buildId>/download/fetch.json`. The requested branch is recorded with `branchProvenance: "caller-asserted"` because the artifact-list request is scoped by build ID and target.
- Artifact sizes are capped at 16 GiB before download, verification, and publication. The CLI requires HTTPS for API and artifact URLs. The Python test API can explicitly opt into loopback HTTP; redirects are still checked, remain on the same loopback origin, and HTTPS cannot redirect to HTTP.
- A second run with the same arguments downloads nothing and re-verifies hashes.

### 2.3 Licensing note

The prebuilt image is used for development only (M1–M4). Release images are built from source by us (§11) so that we control the notices and source offer. Redistribution questions are tracked in [../05-development/legal-and-licensing.md](../05-development/legal-and-licensing.md) and R-10.

---

## 3. Inventory and AndroidImageManifest (#008, #009)

### 3.1 Inventory (#008)

`scripts/inventory-cuttlefish.py <zip or directory> [--out inventory.json]` lists every archive entry and classifies it **by content**. When given a download directory with one archive and `fetch.json`, it checks the sidecar's archive name, size, and SHA-256 against the archive and carries its build ID, target, and caller-asserted branch into the inventory. `fetch.json` is unsigned local metadata; these checks do not prove that `fetch` created it or authenticate its build fields ([android-image-manifest.md](../03-reference/android-image-manifest.md) §4.2). An unpacked directory without fetch metadata is inventoried as a directory. File names are recorded only as hints. #008 requires filename, size, hash, and probable purpose. The tool records more.

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

EROFS size is read from the superblock `blocks` field at byte offset 36 and
scaled by the block-size bits at offset 12. ZIP and directory input bounds,
stable-file checks, and the output-path rule are specified in
[android-image-manifest.md](../03-reference/android-image-manifest.md) §4.5.
Each input is copied into a private, size-bounded seekable snapshot while its
SHA-256 is computed. Classification reads that exact snapshot, so the emitted
digest and parsed metadata always describe the same bytes. For directory files
and ZIP archives, the original input is also re-hashed after parsing; persistent
content changes are rejected even when the filesystem's timestamps do not
change at their available resolution. A transient write that is reverted
during parsing cannot mix one version's digest with another version's
classification. Snapshots use at most 8 MiB of memory, then spill to a
per-user mode-0700 temporary directory. A single input snapshot is limited to
16 GiB; one inventory process per user may hold that scratch budget at a time.
Before copying and every 64 MiB thereafter, the tool checks that enough
temporary space remains for the input plus a 256 MiB reserve. ZIP members are
classified and hashed directly from the immutable archive snapshot, avoiding
a second expanded copy. The temporary snapshot is removed when inventory
finishes.

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

The inventory says *what is there*. The `AndroidImageManifest` says *what each thing is for*. It is written once per build (generated from the inventory by `python3 -m apkrun_image manifest`, then reviewed by a human and committed). Full schema and field rules: [../03-reference/android-image-manifest.md](../03-reference/android-image-manifest.md). The sketch below is abbreviated: hashes are elided, and it leaves out the artifacts `vbmeta_system`, `vbmeta_system_dlkm`, `vbmeta_vendor_dlkm`, and `custom` and six of the nine non-empty logical partitions. The complete example is in the reference, §5.

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
  "android": { "release": "17", "sdk": 37, "variant": "userdebug", "securityPatch": "2026-06" },
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
| `kernel` | Kernel section of the `roles.kernel` boot image. Compression is detected by magic: gzip `1f 8b`, LZ4 legacy `02 21 4c 18`, LZ4 frame `04 22 4d 18`. The kernel is decompressed if needed, because the arm64 kernel has no self-decompressor and `VZLinuxBootLoader` hangs on a compressed kernel. The result must have the arm64 Image magic `ARM\x64` at offset 0x38. `text_offset`, `image_size`, and the page-size bits of `flags` are recorded: code 0 is unspecified, 1 is 4 KiB, 2 is 16 KiB, and 3 is 64 KiB. |
| `ramdisk.img` | Vendor ramdisk fragments from the `vendor_boot` v4 table, in table order, excluding type `RECOVERY`, followed by the generic ramdisk from `init_boot`. This matches the load order vendor ramdisks → generic ramdisk → bootconfig. Fragments are concatenated byte for byte, as a bootloader does; the kernel unpacks concatenated compressed cpio archives. |
| `vendor-bootconfig.txt` | The bootconfig section of `vendor_boot` (for build 16373615: `androidboot.hardware=cutf_cvm` and `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384`). It becomes layer 1 of the bootconfig merge (§6.1). `extract` does not write the bundle's `boot/bootconfig.txt`; `bundle` (§10.2) writes it from this file and the layout. |
| `cmdline.txt` | Vendor cmdline (`printk.devkmsg=on audit=1 panic=-1 8250.nr_uarts=1 binder.impl=rust cma=0 firmware_class.path=/vendor/etc/ loop.max_part=7 init=/init bootconfig`) + the boot image cmdline (normally empty) + the APKRun additions, `cmdline.additions` of the layout file (§6.4). |
| `dtb` | Extracted for the record only. VZ provides its own device tree, so the DTB is not used. |
| `extraction.json` | Input and output SHA-256 values and sizes, tool versions (vendored `unpack_bootimg.py` revision), header fields, the ramdisk table (each fragment with its type and whether it was included), kernel header fields |

#010 acceptance: output includes kernel, ramdisk, extraction metadata, and hashes. Inputs are opened read-only and re-hashed after extraction to prove they were not changed. #010 records the kernel compression, the fragment list, and the command-line length of the pinned build in the verification log (§17).

`bootimg.py` accepts only boot/init_boot v4 and vendor_boot v4. It bounds every
header, payload, table, and fragment range against the source file before
reading it. Vendor page sizes follow the pinned `mkbootimg.py` choices
(2048, 4096, 8192, or 16384 bytes). The table byte size must equal its entry
count times entry size. Fragment ranges retain table order and must cover the
vendor ramdisk exactly without gaps or overlap. Table parsing uses the same
16 MiB and 4096-entry caps as inventory. Fixture section bytes are compared
with the vendored AOSP `unpack_bootimg.py`; the pinned archive is also parsed
through seekable ZIP member streams without extracting the full archive.
Fragment names and command lines use strict UTF-8 decoding to match the
vendored AOSP tools.

`kernel.py` streams decompression and limits output to 1 GiB. Concatenated gzip
members, standard LZ4 frames, and legacy LZ4 frames are decoded as one kernel.
Legacy LZ4 is decoded as size-prefixed blocks with an 8 MiB maximum output per
block; only the final block of each frame may be shorter. The selected build
16373615 kernel is uncompressed: its boot section is 42,031,616 bytes, with
`text_offset` 0, `image_size` 42,795,008, and `flags` 10 (4 KiB page size).
The section can be shorter than `image_size`; that field describes the
effective memory size and is recorded separately from the bytes extracted.

The ramdisk fragment policy (all non-recovery fragments, table order) is what a default AOSP bootloader does when no board-specific selection applies. #013 confirms it against the reference capture by comparing the first-stage module list (`lsmod` and the first-stage init log).

For build 16373615, extraction produced an uncompressed 42,031,616-byte
kernel and one unnamed `PLATFORM` fragment of 18,816,072 bytes, included in
the ramdisk. The vendor_boot table has no `RECOVERY` fragment. The current
layout emits a 172-byte command line: the 144-byte vendor command line, the
empty boot command line, `console=hvc0`, and `log_buf_len=2M` (IR-366). The
#064 `target` capture will not be produced (IR-305), so these two additions are
the ones verified on VZ (§6.6), not provisional values from that capture.

### 4.2 Disk plan (#011)

Cuttlefish under crosvm gives the guest composite disks whose GPT partition names first-stage init and fstab rely on (`/dev/block/by-name/<name>`). APKRun builds raw GPT disk images with the same partition names. The mapping is data (`Images/tools/layouts/cuttlefish-phone-arm64.json`), copied into the runtime manifest, and read by ImageCore. Nothing in Swift lists partitions.

Design rules:

1. **Names mirror Cuttlefish's `os_composite`.** A/B partitions exist only as `_a` (slot `_a` is fixed by bootconfig). Single partitions keep their plain names.
2. **Read-only system disk.** Everything Android never writes in normal operation goes into `os.img`, attached read-only. This is APKRun's read-only base disk.
3. **One writable disk.** `userdata.img` holds every partition Android writes: the small instance partitions (misc, metadata, frp) and `/data`, with `userdata` last so it can grow (§5.2). It is a per-instance clone (§5). There is no third disk: the stock fstab hands `/devices/*/block/vdc` to vold as `sdcard1`, so a third virtio-blk disk would be offered to the user as removable storage (verified 2026-10-08, IR-308).
4. **Partition size = image size, exactly.** AVB hash footers sit in the last 64 bytes of a *partition*. A partition larger than its image would move the footer away from where libavb looks. `super` is sized to the unsparsed logical size recorded in its sparse header, because liblp checks the block device size.
5. **Partitions not needed on VZ are left out.** `uboot_env`, the persistent `bootconfig` partition, and the persistent vbmeta (AVB persistent values) serve U-Boot only. `android_esp` serves EFI boot only. `pvmfw_a` and `vvmtruststore` serve protected VMs (`hypervisor.vm.supported=0`). `hibernation` is unused. Each omission is confirmed in #011 against the reference `ls -l /dev/block/by-name` and the fstab. If an omitted partition turns out to be required, it is added blank.

Verified plan (corrected from three disks to two by the 2026-10-08 spike, confirmed by #011 on 2026-10-09: the Linux test guest saw `vda` with the nine partitions and `vdb` with the four, at the `disks.json` offsets and sizes; `Images/reference/vz/26A434/topology.txt`). The data is the `disks` section of `Images/tools/layouts/cuttlefish-phone-arm64.json`; each correction is recorded in §13:

| VZ disk (attach order) | File | Access | `blockDeviceIdentifier` | GPT partitions (label ← source) | Guest name |
|---|---|---|---|---|---|
| 0 | `Images/<v>/disks/os.img` | read-only | `apkrun-os` | `boot_a` ← boot.img · `init_boot_a` ← init_boot.img · `vendor_boot_a` ← vendor_boot.img · `vbmeta_a` ← vbmeta.img · `vbmeta_system_a` ← vbmeta_system.img · `vbmeta_system_dlkm_a` ← vbmeta_system_dlkm.img · `vbmeta_vendor_dlkm_a` ← vbmeta_vendor_dlkm.img · `super` ← super.img (unsparsed) · `custom` ← cuttlefish_example_custom.img | `/dev/block/by-name/<label>` |
| 1 | `Runtime/instance/userdata.img` | read-write | `apkrun-data` | `misc` ← blank · `metadata` ← blank · `frp` ← blank · `userdata` ← blank (primary) or template (§5.2), last | same |

Notes:

- `boot_a`, `init_boot_a`, and `vendor_boot_a` are not read by the direct boot itself; the kernel and ramdisk come from `boot/`. They are present because vbmeta describes them and because Android components (update_verifier, the boot control HAL, dumpstate) may open them. They cost no extra space in the bundle download beyond the images themselves.
- If #013/#014 show that a component needs `_b` partitions to exist, equal-sized zero-filled `_b` partitions are added. On APFS they are holes and cost nothing.
- The identifiers are for logs and host-side lookups only. Android finds partitions by GPT name.

### 4.3 Sparse to raw

`sparse.py` implements the Android sparse format directly (28-byte file header, magic `0xED26FF3A`, 12-byte chunk headers; RAW `0xCAC1`, FILL `0xCAC2`, DONT_CARE `0xCAC3`, CRC32 `0xCAC4`):

- The output is written straight into the partition's range inside `os.img`. There is no intermediate file.
- DONT_CARE chunks and zero FILL chunks become holes (`seek`), so `os.img` uses only as much physical space as the data. The same holds for every 4 KiB block of a RAW chunk, and of a raw partition, that is all zeros (#065, `write_skipping_zeros`). Before #065 those zeros were written, and the stock `os.img` took about 8 GB where its data is 1.8 GB.
- CRC32 chunks are verified when present. The total block count must equal the header's `total_blks`.
- T1 test: for the fixture sparse images and for the real `super.img`, the output hash equals `simg2img` output (simg2img 1.1.5; the expected hashes are committed in `Images/tools/tests/fixtures/sparse/expected-sha256.txt`). The real `super.img` expands to 8 GiB with SHA-256 `7dd80d27…85e3b5`.

### 4.4 GPT writer

`gpt.py` writes and reads GPT for 512-byte logical sectors (the VZ virtio-blk sector size is confirmed with `blockdev --getss` in #005 and #011):

- Protective MBR, primary header at LBA 1, 128 entries × 128 bytes at LBA 2–33, backup entries and backup header at the end of the disk, CRC32 over header and entry array.
- Partitions start on 1 MiB boundaries. Sizes follow rule 4 of §4.2.
- Type GUID: Linux filesystem data (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`) for every partition. Android does not look at type GUIDs.
- Unique partition GUIDs and the disk GUID are deterministic: UUIDv5 over (`imageVersion`, disk role, label) for `os.img` and the templates. Per-instance disks get new disk GUIDs at provisioning (§5.1) so that two instances would never collide.
- Names: UTF-16LE, at most 36 code units, case-sensitive.
- Reader side: the same module parses GPTs for tests and for `apkrun_image inspect`. ImageCore has its own minimal GPT reader/writer in Swift for §5.2 (`GPTDisk`: header relocation only, no partition creation). Provisioning in both languages (`gpt.provision_disk`, `GPTDisk.provision`) zeroes the old backup GPT, writes both copies for the new size, grows the last partition to the new last usable sector, and gives the disk and partitions GUIDs that are UUIDv5 values over `instance/<instance UUID>/<role>[/<label>]` in the same namespace. Both are pinned to `Images/tools/tests/fixtures/gpt/provision.json`.

### 4.5 Assembly and verification

`python3 -m apkrun_image disks --manifest … --layout layouts/cuttlefish-phone-arm64.json [--image-version <v>] --out Images/work/<buildId>/disks/` produces `os.img`, `userdata.img` and `disks.json`. Per disk, `disks.json` has the file, role, access, identifier, sector size, logical size, disk GUID, and `userdataStrategy`; per partition, the label, GUID, first and last LBA, size, source, content kind (`blank` or the artifact kind), and the SHA-256 of the partition contents. Each artifact is hashed while it is copied and must equal its manifest SHA-256. For build 16373615 the command takes about 20 s; `os.img` is 8.1 GiB logical and 1.8 GiB allocated, and `userdata.img` is an 82 MiB template that is all holes. `python3 -m apkrun_image inspect <disk>` prints the partition table.

#011 acceptance ("Android kernel detects expected virtio block devices") is checked twice:

1. T2 with the Linux test guest ([vm.md](vm.md) §12): the two disks are attached, and `/init` prints `PARTNAME` from `/sys/class/block/vd*/uevent` and the size of each partition. The test compares them with `disks.json`.
2. T2 with the Android kernel (#012): the console log shows `virtio_blk` detecting two disks with the expected partition counts (9 and 4).

---

## 5. Instance disks (#066, #011)

### 5.1 Provisioning

The instance is created on first run (#066) or by "Reset Android" (FR-OPS). Steps, all inside `Runtime/instance/`:

1. Create `instance.json` with a new instance UUID, `VZGenericMachineIdentifier`, a locally administered MAC, CPU/memory sizing ([vm.md](vm.md) §10), `imageVersion`, `userdataSchemaVersion` from the image manifest, and a new `userdataGeneration` UUID. APKStoreCore compares that generation with its package records to find packages that must be reinstalled ([package-store.md](package-store.md) §9.2). Restoring a recovery point (§12.2) also writes a new `userdataGeneration`.
2. `clonefile(2)` `Images/<v>/templates/userdata.img` → `userdata.img`. Clones are instant on APFS and share blocks until written. If the Application Support volume is not APFS, provisioning fails with `ImageFailure.cloneUnsupported` (APKRun does not fall back to full copies of multi-GB files; NFR-RES).
3. Give the disk a new disk GUID and new partition GUIDs (derived from the instance UUID) and rewrite the GPT CRCs.
4. Grow `userdata.img` to the configured size (§5.2).
5. `fsync` the files and the directory, then write `instance.json` last. An `instance.json` without its disks means an interrupted provisioning, and provisioning starts over.

### 5.2 userdata: format, size, growth

Primary approach: **blank userdata, formatted by Android on first boot.**

- The template holds a GPT with the blank `misc`, `metadata`, and `frp` partitions and a last `userdata` partition, and no data (the file is all holes).
- At provisioning ImageCore extends the file with `ftruncate` to the configured size (sparse, so no physical space is used). It then moves the GPT backup header and entry array to the new last LBAs, updates `alternate_lba` and `last_usable_lba` in the primary header, extends the `userdata` partition's `ending_lba` to the new last usable LBA, and recomputes the CRCs.
- Cuttlefish's fstab marks `/data` (and `/metadata`) `formattable`. On first boot, fs_mgr/vold format the empty partition at its full size. Confirmed on VZ on 2026-10-08: `fstab.cf.f2fs.hctr2` has `formattable` and `keydirectory=/metadata/vold/metadata_encryption`, and the first boot formatted both blank partitions (IR-306).

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

On VZ all virtio-blk devices sit behind the single `pci-host-ecam-generic` bridge at `0x40000000` ([vm.md](vm.md) §5), so one value covers both disks. Observed value (2026-10-08, macOS 27.0.1 26A434): **`40000000.pci`**; `/sys/block/vda` resolves to `/sys/devices/platform/40000000.pci/pci0000:00/0000:00:0f.0/virtio12/block/vda`, and `/dev/block/by-name/` holds every label of §4.2.

Discovery (#011):

1. Boot the Linux test guest with the two disks. `/init` prints `readlink -f /sys/block/vda` (expected shape: `/sys/devices/platform/<addr>.<node>/pci0000:00/0000:00:NN.0/virtioM/block/vda`).
2. The platform component (for example `40000000.pci` or `40000000.pcie`, depending on the DT node name) is the value.
3. The value is stored with the topology capture in `Images/reference/vz/<macOS build>/topology.txt` (first capture: `Images/reference/vz/26A434/topology.txt`), and compiled into ImageCore as `VZPlatformProfile.bootDevices` (host-platform data, not image data). The T2 suite re-checks it on every new macOS build (R-16): `LinuxGuestAndroidDiskLayoutTests` asserts that both disks sit under `40000000.pci`.
4. The Android boot (#013) confirms that `/dev/block/by-name/` contains every label from §4.2.

Alternative if the path is not stable across macOS versions: `androidboot.boot_part_uuid`. It names one partition's unique GUID and makes that partition's *disk* the boot device, so it only works if all partitions are on one disk. The fallback layout would put `super` and the other `os.img` partitions on the read-write disk. That is kept as a documented fallback, not built unless needed.

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
- The key/value tree must contain at most 1024 nodes, counting each distinct dotted-key component once and one value node per key. The tool checks this independently of byte size.
- The serialized block must be at most 32 KiB (kernel limit). The build tool fails above 16 KiB to leave room for layers 3–4.

### 6.2 Key catalogue (initial)

"Reference" means #064 captures Cuttlefish values from `target` and #010 copies them into the initial layer-2 layout. The image layer also includes values computed by `avb.py`. #013 compares a live VZ boot with the reference; if evidence shows direct boot needs a different layer-2 value, #013 updates the VZ layout to the observed value and records the key and reason in `expected-differences.yaml`. The original reference value remains in #064's capture. The table is the checklist; the layout file is the source of truth.

| Key | Value | Layer | Status |
|---|---|---|---|
| `androidboot.hardware` | `cutf_cvm` | 1 | verified (vendor_boot) |
| `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size` | `16384` | 1 | verified |
| `androidboot.slot_suffix` | `_a` | 2 | decided (ADR-0015) |
| `androidboot.force_normal_boot` | `1` | 2 | verified on VZ (2026-10-08) |
| `androidboot.verifiedbootstate` | `orange` | 2 | decided for dev images; production in §11.4 |
| `androidboot.vbmeta.device_state` | `unlocked` | 2 | same |
| `androidboot.vbmeta.{digest,hash_alg,size,avb_version,invalidate_on_error}` | computed by `avb.py` from top-level vbmeta and every chained vbmeta blob | 2 | computed at build time |
| `androidboot.fstab_suffix` | `cf.f2fs.hctr2` (launcher capture) | 2 | verified on VZ |
| `androidboot.console`, `androidboot.serialconsole` | `hvc1` and `1` in developer mode (the init `console` service runs `sh` on hvc1); omitted otherwise | 4 (developer mode) | verified on VZ |
| `androidboot.hw_timeout_multiplier` | `3` (launcher capture) | 2 | verified on VZ |
| `androidboot.hypervisor.vm.supported` | `0` | 2 | decided (arm64 default). The VZ spike set `0`, and the reference does not set the key, so the value is not checked against the reference (IR-404) |
| `androidboot.vendor.apex.com.android.hardware.keymint` | `com.android.hardware.keymint.rust_nonsecure` (§7.2) | 2 | verified on VZ; the launcher's default selection |
| `androidboot.vendor.apex.com.android.hardware.gatekeeper` | `com.android.hardware.gatekeeper.nonsecure` (§7.2) | 2 | verified on VZ; the launcher's default selection |
| `androidboot.vendor.apex.com.android.hardware.{weaver,strongbox}` | `none` | 2 | verified on VZ (launcher capture) |
| `androidboot.vendor.apex.com.android.hardware.secure_element`, `…com.google.emulated.camera.provider.hal` | the launcher's values | 2 | verified on VZ |
| `androidboot.vendor.apex.com.android.hardware.graphics.composer` | `com.android.hardware.graphics.composer.ranchu` | 2 (GPU profile) | verified on VZ with the `headless` profile |
| `androidboot.vendor.apex.com.google.cf.vulkan` | per GPU profile (none for `drm_virgl`) | 2 (GPU profile) | absent from the launcher capture and not committed; no profile sets it |
| Graphics props (`androidboot.hardware.egl=mesa`, `…gralloc=minigbm`, `…hwcomposer=ranchu`, `…hwcomposer.mode=client`, `…hwcomposer.display_finder_mode=drm`, `androidboot.cpuvulkan.version=0`, `androidboot.opengles.version=196608`) | as listed for `drm_virgl`; the `guest_swiftshader` profile has its own set ([graphics.md](graphics.md) §9) | 2 (GPU profile) | `guest_swiftshader` and `headless` keys verified against the launcher capture (IR-305). The `drm_virgl` set is source-derived (`graphics-props-from-source.txt`); no capture or VZ run confirms it, and #022 does (IR-400, IR-401) |
| `androidboot.wifi_impl` | `virt_wifi` (§7.4) | 2 | verified on VZ |
| `androidboot.wifi_mac_prefix` | the launcher's `5554`; `setup_wifi` derives eth2's MAC from it (§7.4) | 2 | verified on VZ |
| `androidboot.modem_simulator_ports` | `9600`. The RIL exits without it; with it, the RIL stays up without a modem (§7.3) | 2 | verified on VZ |
| `androidboot.vsock_lights_{port,cid}`, `androidboot.vendor.audiocontrol.server.{port,cid}`, `androidboot.openthread_node_id` | the launcher's values: they configure guest-side servers, whose HALs abort without them (§7.3) | 2 | verified on VZ |
| `androidboot.vsock_tombstone_port`, `androidboot.vhal_proxy_server_port`, `androidboot.auto_eth_guest_addr` | omitted: host services or automotive only (§7.3) | — | verified on VZ |
| `androidboot.cuttlefish_service_bluetooth_checker` | `false`: the boot reporter does not wait for Bluetooth, as on Cuttlefish's automotive product (§7.6) | 2 | verified on VZ |
| `androidboot.enable_bootanimation`, `androidboot.enable_confirmationui`, `androidboot.setupwizard_mode` | the launcher's `1`, `1`, `DISABLED` | 2 | verified on VZ |
| `androidboot.boot_devices` | `VZPlatformProfile.bootDevices` = `40000000.pci` (§5.3) | 3 | verified on VZ; #011 records `topology.txt` |
| `androidboot.serialno` | `APKRUN` + first 10 hex digits of the instance UUID, upper case | 4 | decided |
| `androidboot.lcd_density` | density of display 0 = 160 × backing scale ([display-and-windowing.md](display-and-windowing.md)) | 4 | decided |
| `androidboot.ddr_size` | VM memory size as `<MiB>MB` (the launcher writes `4915MB` for crosvm's 4096 MiB plus its overhead) | 4 | verified on VZ (`4096MB`) |
| `androidboot.apkrun.instance` | instance UUID | 4 | decided |
| `androidboot.apkrun.devmode` | `0` or `1` (custom image only, §11.3) | 4 | decided |
| `androidboot.apkrun.image` | `imageVersion` | 4 | decided |
| `androidboot.apkrun.test.*` | test image bundles only, never in release bundles (a CI check on the release manifest): `marker=<value>` identifies a test bundle in the migration test (§12.4); `fail_health=1` makes the Guest Agent report unhealthy (§12.4); `fail_boot=1` makes the product's init stop `zygote` before `sys.boot_completed`, so the boot times out ([diagnostics.md](diagnostics.md) §12 T2-4) | 2 (test layout of test bundles) | decided |

AVB metadata follows the top-level vbmeta chain descriptors in their stored
order. `roles.vbmeta` lists the raw vbmeta artifacts in that same relative
order. Other chained partitions, such as `boot` and `init_boot`, remain their
own manifest artifacts; if they carry an AVB footer, `avb.py` reads the
footer-referenced vbmeta blob at its declared offset. The digest covers each
AVB0 header, authentication block, and auxiliary block, in chain order, and
excludes partition padding and the footer. `hash_alg` follows the top-level
signature algorithm (`NONE` uses SHA-256), and `size` is the sum of those
metadata blob sizes. `avb_version` follows the pinned AVB 1.4 toolchain. The
build uses the explicit `restart_and_invalidate` hashtree policy by default;
`invalidate_on_error` is `yes` for that policy and `no` when the top-level
vbmeta disables hashtrees or another policy is selected. `avb.py` rejects a
top-level vbmeta with `VERIFICATION_DISABLED`; libavb emits no AVB-derived
`androidboot.*` options when that flag is set.

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
- Anything else that `/proc/cmdline` in the reference capture shows beyond the vendor cmdline and that is not bootconfig-able (non-`androidboot` kernel parameters). Each addition is listed in the layout file with a comment on where it came from. The first addition after `console=hvc0` is `log_buf_len=2M`, so that `dmesg` keeps the boot's first lines until the serial shell answers (§6.6, CF-18).

`androidboot.*` parameters are never put on the cmdline. The total length must fit the VM validation limit of 2048 bytes ([vm.md](vm.md) §3).

### 6.5 Verification on VZ (#012)

Checked on macOS 27.0.1 (26A434), build 16373615, with the Android kernel `6.12.74-android16-6-g3ec022196c4e-ab15076761-4k` (`boot/kernel`).

- **Kernel path and timing.** From `apkrun dev boot` on the product code (`boot-20261009T015535Z.log`), with kernel uptime: the first console line at 0.20 s; `vda` and `vdb` probed at 0.28 s and 0.29 s with nine and four partitions; `[drm] pci: virtio-gpu-pci detected` at 0.31 s; the first `init:` line at 0.34 s; `init: init second stage started!` at 0.43 s; `starting service 'zygote'` at 1.32 s; `VIRTUAL_DEVICE_BOOT_COMPLETED` at 5.18 s.
- **Missing from hvc0.** `Booting Linux on physical CPU`, `Kernel command line:`, and the first-stage loads of `virtio_console` and `virtio_net` are written before hvc0 exists, so the console never shows them (IR-306, IR-360). #013 reads them over the serial shell (`su 0 dmesg`, `/proc/cmdline`, `/dev/rtc0`, `/sys/bus/virtio/drivers/`). Among the devices the console can show, none is missing.
- **Bootconfig.** The Linux test kernel (Alpine `linux-virt` 6.18.54) has no `CONFIG_BOOT_CONFIG`, so `/proc/bootconfig` does not exist there. The Android check of `/proc/bootconfig` against the merged block is in #013 (IR-362).
- **Truncated ramdisk.** The ramdisk is LZ4 (legacy). A cut ramdisk fails while the kernel unpacks it, before `virtio_console` exists, so no panic text reaches hvc0. The boot then ends with `bootStalled(kernel)` (IR-361).

### 6.6 Init checks on VZ (#013)

`AndroidBootTests.testReachesInit` checks these on the product path (`RuntimeSupervisor` in developer mode, `AndroidShellConsole` over hvc1). The run of 2026-10-09 (macOS 27.0.1 (26A434), build 16373615, headless profile) passed in 15.3 s.

- **Debug ramdisk: not used.** The bundle lists only `boot/kernel` and `boot/ramdisk.img`, and no `boot-debug.img` or `vendor_boot-debug.img`. Build 16373615 is `userdebug` with `ro.debuggable=1`, so the debug ramdisk adds nothing (the decision of #013 step 5).
- **fstab.** `androidboot.fstab_suffix=cf.f2fs.hctr2` selects `/vendor/etc/fstab.cf.f2fs.hctr2`. `/metadata` mounts as `ext4` and `/data` as `f2fs`, both `rw`.
- **Dynamic partitions.** First-stage init created the nine non-empty logical partitions of slot `_a` (the empty `_b` ones are skipped). The system partitions mount read-only from `dm-9` to `dm-16`.
- **Boot device names.** `/dev/block/by-name` has every GPT label of the disk plan in the manifest (`boot_a`, `init_boot_a`, `vbmeta_a`, `super`, `custom`, `misc`, `metadata`, `frp`, `userdata`, and the rest). `androidboot.boot_devices=40000000.pci` puts `vda` and `vdb` on the bus (§5.3).
- **AVB.** The unsigned development vbmeta gives `OK_NOT_SIGNED`, an unknown key, and `VerificationError` for `/system` and `/system_dlkm`. The dm-verity tables are built and the boot continues with `verifiedbootstate=orange`. No other `libfs_avb` error appears (CF-16, IR-364).
- **Bootconfig.** `/proc/bootconfig` equals the planner's merged block, key for key and value for value (§6.1).
- **SELinux.** `getenforce` is `Enforcing`, and the boot's dmesg has no AVC denial. No permissive workaround is set, so no TODO is needed.
- **Kernel log.** The default 256 KiB log buffer wraps before the serial shell answers, about 1,000 lines later. The first-stage and kernel-start lines were gone from `dmesg`. `log_buf_len=2M` keeps them (CF-18, IR-366). With it, `dmesg` shows `Booting Linux on physical CPU`, `Kernel command line`, `init: init first stage started!`, and `init: init second stage started!`.
- **Command line.** `/proc/cmdline` is the bootconfig `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size` key, then the kernel's built-in command line (`console=ttynull stack_depot_disable=on cgroup_disable=pressure kasan.stacktrace=off kvm-arm.mode=protected bootconfig`), then `cmdline.txt` unchanged (IR-365). The kernel logs `KVM is not available. Ignoring kvm-arm.mode` (CF-17).
- **Devices.** The bound drivers are `virtio_net` (device 1), `virtio_blk` (2), `virtio_console` (3, the hvc ports), `virtio_rng` (4), `virtio_gpu` (16), and `vmw_vsock_virtio_transport` (19). `/dev/rtc0` exists. The balloon device (id 5) has no driver, because no balloon module is in the first-stage ramdisk or among the modules the boot loads (IR-369).
- **Modules.** First-stage init loaded 19 modules from `/lib/modules`, and the booted system has 67. The bundle has one unnamed PLATFORM ramdisk fragment and no RECOVERY fragment (§4.1), so there is no recovery module set to leave out, and the fragment policy needs no change.
- **Logs.** The shell checks ran with short commands. Long command lines are echoed with line-editing artifacts on hvc1, so the test writes `dmesg` to a file on the guest first (IR-370).

---

## 7. Cuttlefish host-service substitution (#095)

Cuttlefish's guest expects host processes (launcher, `secure_env`, `modem_simulator`, rootcanal, GNSS proxy, sensors simulator, `socket_vsock_proxy`, …) that APKRun does not run. #095 decides, port by port and service by service, what APKRun provides instead. Guiding rule: **prefer in-guest implementations selected by configuration over host-side re-implementations**, and do not remove guest services unless they are shown to break boot, stability, or resource use (#035: "Do not aggressively remove services").

### 7.1 Console port plan

Cuttlefish attaches 20 single-port virtio-console devices. Some HALs open fixed `/dev/hvcN` nodes, so the numbering must match. APKRun attaches all 20 ports in the same order, after the numbering check in [vm.md](vm.md) §6.2. VZ accepts at most 10 single-port devices, so VirtualMachineCore attaches ports 0–9 that way and ports 10–19 as the console ports of one multiport device ([vm.md](vm.md) §6.1); the guest numbers them hvc10–hvc19 in array order (observed 2026-10-08: the sensors HAL's frames arrived on port 18). The plan is data in the runtime manifest (`consolePorts`), turned into `ConsolePortDefinition`s by ImageCore.

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
| hvc18 | sensors control | `.service("sensors")`: the "no sensors" responder | the HAL waits for the reply to `list-sensors` before it registers, and `system_server` blocks on it (see below) |
| hvc19 | sensors data | `.silent` | kept open; with mask 0 the host never writes |

`.silent` ports are attached (so the device node exists and opens succeed) but the host never writes. A HAL that blocks reading a silent port just waits; a HAL that times out and crash-loops is recorded in #095 and handled in §7.6. Leaving a port out is worse: oemlock (hvc10) and the sensors HAL abort with `No such device` and crash-loop. On the 2026-10-08 VZ boot, the holders were hvc1 (`sh`), hvc2 (`logcat`), hvc5 (Bluetooth), hvc8 (confirmationui), hvc9 (UWB), hvc10 (oemlock), hvc12 (NFC), and hvc18/hvc19 (sensors).

**Sensors responder.** The stock sensors HAL (`android.hardware.sensors@2.1-impl.cuttlefish.so`, `device/google/cuttlefish/shared/sensors/multihal/entry.cpp` on `android17-release`) opens the hard-coded `/dev/hvc18` and `/dev/hvc19`, sends `list-sensors` on hvc18, and blocks in `ReadExactBinary` for the reply, with no timeout. The multihal service registers `ISensors/default` only after that, so a silent hvc18 blocks `SensorService` and then the `system_server` main thread in `SystemSensorManager.nativeCreate`; the framework Watchdog kills `system_server` after 185 s, again on every restart. No bootconfig key selects another sensors implementation in this build. RuntimeCore therefore answers on hvc18, the minimal adapter of [AGENTS.md](../../AGENTS.md) §15:

- Framing (`common/libs/transport/channel.h`): a little-endian `u32` of `command | is_response << 31`, a little-endian `u32` payload size, then the payload.
- A payload that starts with `list-sensors` gets the frame the real `sensors_simulator` sends for an empty sensor mask: command 2 (`kUpdateHal`) with `is_response`, payload `"0\n"` (`02 00 00 80 02 00 00 00 30 0a`).
- Everything else the HAL sends (`time:<ns>`, `set-delay:<ms>`, `set:<name>:<0|1>`) needs no answer and is discarded. The parser starts empty on every boot.
- Android then reports no sensors (`host sensors mask=0`). Sensor data from the Mac is post-v1.

If VZ ever limits console devices further, the fallback is: attach ports 0–N in order, and the custom image (§11) points the affected HALs elsewhere or disables them.

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
| Guest → host clients (tombstone transmit, modem simulator, camera, vehicle HAL proxy) | configured by `androidboot.vsock_tombstone_port`, `modem_simulator_ports`, `vsock_camera_*`, and `vhal_proxy_server_port` | `vsock_tombstone_port` and `vhal_proxy_server_port` are omitted, and their clients stay unconfigured. `modem_simulator_ports=9600` stays: without it `radio-service.cf` exits at once and init restarts it every 5 s. With it, the RIL's connection to host vsock 9600 is reset (no listener), and the RIL stays up reporting `RADIO_NOT_AVAILABLE` (verified 2026-10-08). The camera keys are not in the launcher capture |
| Guest-side servers (lights, audio control, OpenThread) | `androidboot.vsock_lights_{port,cid}`, `androidboot.vendor.audiocontrol.server.{port,cid}`, and `androidboot.openthread_node_id` configure servers that listen in the guest | the launcher's values stay. Without them `light-service.cuttlefish` aborts on `Permission denied`, the OpenThread HAL aborts on `node_id > 0`, and init restarts them in a loop (verified 2026-10-08) |
| APKRun agents | — | vsock 6100–6111 via `apkrun_vsockd` on custom images ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3) |
| Reserved for substitutes | — | vsock 6120–6199. v1 is host-initiated only. A substitute that needs guest-initiated connections requires vsock listeners in `VMDefinition` and an ADR. |

### 7.4 Network

Cuttlefish attaches several NICs (mobile, ethernet, Wi-Fi backends), and guest scripts rename interfaces and set up `virt_wifi` on top of one of them, chosen by `androidboot.wifi_impl`. APKRun started with one NAT NIC ([vm.md](vm.md) §7).

#095 establishes connectivity in this order and stops at the first option that works. The 2026-10-08 spike showed that option 1 cannot work with the stock image, and that option 2 does:

1. **Single NIC as Wi-Fi.** One NAT NIC, with bootconfig and properties arranged so the guest puts `virt_wifi` on it (apps see an unmetered Wi-Fi network, which is best for compatibility).
2. **Cuttlefish NIC order.** Several NAT NICs in Cuttlefish's order so the stock scripts find what they expect. This changes `VMDefinition.network` from one optional NIC to an ordered list (a small VirtualMachineCore change, noted in [vm.md](vm.md) §7).
3. **Ethernet.** Custom image only: add the ethernet feature and let `EthernetManager` run DHCP on `eth0`.

Checks (T2): `ip addr`, a default route, DNS resolution, `generate_204` from inside Android, and `dumpsys connectivity` showing a validated network.

**Verified configuration (option 2, 2026-10-08).** Three NAT NICs in Cuttlefish's order:

| NIC | Guest name | Use | MAC |
|---|---|---|---|
| 0 | `eth0`, renamed `buried_eth0` by `rename_eth0` | Cuttlefish's mobile NIC; unused without a modem | per instance (`instance.json`) |
| 1 | `eth1` | Cuttlefish's ethernet NIC. The OpenThread HAL forks `ot-rcp -Leth1` and exits with an I/O error if it is missing | per instance |
| 2 | `eth2`, the `virt_wifi` backing NIC (`ro.vendor.virtwifi.port`) | Wi-Fi | `02:XX:YY:00:00:00`, where `XXYY` is `androidboot.wifi_mac_prefix` as a 16-bit number (`5554` → `02:15:b2:00:00:00`) |

- `androidboot.wifi_impl=virt_wifi` makes `init.cutf_cvm.rc` start `setup_wifi`, which creates `wlan0` on `eth2`. The stock `mac80211_hwsim_virtio` path needs crosvm's virtio Wi-Fi device and an OpenWRT access-point VM, which VZ cannot provide.
- `setup_wifi` first rewrites `eth2`'s MAC from `wifi_mac_prefix`. vmnet drops frames whose source MAC it did not assign, so the VZ NIC is created with that MAC already, and DHCP then works.
- Wi-Fi is off on a fresh `/data`. The first boot turns it on and joins the open `VirtWifi` network (§7.6, first-boot settings); Cuttlefish's automotive product does the same in `wifi_on.sh`. The setting persists in `/data`.
- Result (2026-10-08 spike): `wlan0` gets `192.168.64.x/24` from vmnet's DHCP, NetworkMonitor validates the network (`generate_204`), and DNS resolves. ICMP to the internet gets no reply through vmnet; TCP and UDP work. On 2026-10-10 the network validated, and the name resolved as root. The serial shell's `ping` could not resolve it, because the shell cannot reach netd's DNS proxy on this image (§7.8, IR-555).
- Ethernet on `eth1` gets no network request while the Wi-Fi network is up, so it stays unconfigured.

### 7.5 Audio

- Cuttlefish passes virtio-snd to the guest. The guest uses the AIDL audio HAL with `ro.hardware.audio.primary=goldfish` on a tinyalsa card/device.
- APKRun attaches `VZVirtioSoundDeviceConfiguration` ([vm.md](vm.md) §11).
- #083 verifies: `virtio_snd` is loaded (`lsmod`, or built in), `/proc/asound/cards` shows the card, a test tone from HelloAudio (or `tinyplay`) is heard on the host, and the negotiated rate/format is logged. If the module is missing from the stock image, the custom image adds it (§11).
- Microphone input: [vm.md](vm.md) §11 and #084.

### 7.6 Other guest expectations

| Area | Stock behaviour expected without host services | v1 handling |
|---|---|---|
| Input (vhost-user virtio-input from `cf_vhost_user_input`) | no touchscreen/keyboard devices from Cuttlefish | Not reproducible on VZ. Input goes through the Guest Agent ([input.md](input.md), ADR-0013). The USB keyboard/pointer are not attached to the Android VM. |
| Telephony (RIL ↔ `modem_simulator`) | the RIL stays up and reports `RADIO_NOT_AVAILABLE` when `modem_simulator_ports` is set (§7.3) | Accept for stock. The custom image disables the RIL only if #095 measures crash-loops or CPU/log cost. |
| Bluetooth | `bt_hci` opens hvc5 and stays up; the Bluetooth stack (`com.android.bluetooth`) aborts in `waitForInitialization: Can't start HAL` about every 25 s. BluetoothManagerService gives up after its sixth recovery: seven aborts in about 3.5 minutes on every boot while Bluetooth is on. `androidboot.vendor.apex.com.google.cf.bt=none` removes the HAL but not the aborts. The boot reporter waits for Bluetooth and reports `VIRTUAL_DEVICE_BOOT_FAILED: Dependencies not ready after 10 checks: Bluetooth` | `androidboot.cuttlefish_service_bluetooth_checker=false`, and Bluetooth is turned off by the first-boot settings. No Bluetooth in v1 |
| NFC, UWB, GNSS, confirmationui, oemlock | HALs hold their silent ports and wait | same rule as telephony |
| Sensors | the HAL blocks boot unless hvc18 answers (§7.1) | the "no sensors" responder |
| Camera | none | post-v1 |
| Battery, health, thermal | Cuttlefish HALs report fixed values (charging, full) | keep |
| RTC | PL031 exists on VZ; the GKI driver must be present | `/dev/rtc0` exists and `date` is correct (2026-10-08). Time sync is also done by the Guest Agent ([desktop-integration.md](desktop-integration.md) §9). |
| Power button (PL061 + gpio-keys) | VZ `requestStop` presses it; Android treats it as a screen-off key | shutdown goes through the Guest Agent ([vm.md](vm.md) §9.3) |

**First-boot settings.** Two stock defaults need a runtime setting that bootconfig cannot express: Wi-Fi is off, and Bluetooth is on. After the first `.bootCompleted` of a fresh instance, RuntimeCore applies them once through standard Android commands, the way Cuttlefish's automotive `wifi_on.sh` does: `cmd bluetooth_manager disable`, `cmd wifi set-wifi-enabled enabled`, and `cmd wifi connect-network VirtWifi open`. Each is persisted in `/data`, so later boots need nothing. In M1 the channel is the serial shell (developer mode); from #072 the Guest Agent applies them, and the custom image (#035) sets the defaults in its overlays instead. Turning Bluetooth off right after `.bootCompleted` lands before the first stack abort, so even the first boot has none (verified 2026-10-08).

### 7.7 Boot phase markers

The pinned Cuttlefish 1.57.0 host package contains these `VIRTUAL_DEVICE_*`
tokens: `VIRTUAL_DEVICE_BOOT_STARTED`, `VIRTUAL_DEVICE_BOOT_PENDING`,
`VIRTUAL_DEVICE_BOOT_COMPLETED`, `VIRTUAL_DEVICE_BOOT_FAILED`,
`VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED`, `VIRTUAL_DEVICE_SCREEN_CHANGED`,
`VIRTUAL_DEVICE_NETWORK_ETHERNET_CONNECTED`,
`VIRTUAL_DEVICE_NETWORK_MOBILE_CONNECTED`, and
`VIRTUAL_DEVICE_NETWORK_WIFI_CONNECTED`. The `kernel_log_monitor` binary
contains all nine. The `run_cvd` binary contains only
`VIRTUAL_DEVICE_BOOT_COMPLETED` and `VIRTUAL_DEVICE_BOOT_FAILED`. RuntimeCore's
`BootPhaseDetector` uses the boot tokens alongside `sys.boot_completed` read
over ADB (M1) or reported by the Guest Agent (M3+)
([runtime-daemon.md](runtime-daemon.md)).

The observed strings and timings come from incomplete diagnostic records, not
from a reference boot. `Images/reference/16373615/boot-signals.json`, generated
by `Images/tools/reference/boot_signals.py`, summarizes 62 records; 54 contain a
`kernel.log`.

| Token (exact text) | Where it was observed | Timing |
|---|---|---|
| `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON` | guest `kernel.log`, 28 records | guest uptime of the first occurrence: median 569.6 s (min 198.9 s, max 965.8 s) |
| `VIRTUAL_DEVICE_BOOT_FAILED` | host `run_cvd` lines in `launcher.log` (`boot_state_machine.cc:211`) and `cvd-create-console.log`, 13 records; not in any guest `kernel.log` | host wall-clock only; no guest uptime |
| `VIRTUAL_DEVICE_BOOT_COMPLETED` | not observed; the text appears only in prose in the records | unknown |
| `VIRTUAL_DEVICE_BOOT_STARTED`, `VIRTUAL_DEVICE_BOOT_PENDING`, `VIRTUAL_DEVICE_SCREEN_CHANGED`, `VIRTUAL_DEVICE_NETWORK_*` | not observed | unknown |

`VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED` lines carry `display=<n> mode=<state>`
fields. Display-state lines and host failure lines are not boot-completion
signals. No #064 record reaches `sys.boot_completed=1`.

**Observed on VZ (2026-10-08, IR-306).** The VZ direct boot confirms the strings.
The guest's `GceEventReporter` writes them to the kernel log, so on hvc0 they
appear as `GceEventReporter: VIRTUAL_DEVICE_<TOKEN>` after the kmsg prefix.
Guest uptime over the five cold boots of `g2_spike.py` (boot 1 on a fresh
instance; boots 2–5 on the same instance):

| Token on hvc0 | Boot 1 | Boots 2–5 |
|---|---|---|
| `init: starting service 'zygote'...` | 1.48 s | 0.95–1.18 s |
| `VIRTUAL_DEVICE_DISPLAY_POWER_MODE_CHANGED display=0 mode=ON` | 1.90 s | 1.24–1.63 s |
| `GceEventReporter: VIRTUAL_DEVICE_BOOT_STARTED` | 6.54 s | 3.00–3.73 s |
| `GceEventReporter: VIRTUAL_DEVICE_BOOT_COMPLETED` | 7.49 s | 3.95–4.67 s |
| `GceEventReporter: VIRTUAL_DEVICE_NETWORK_WIFI_CONNECTED` | 21.6 s (after the first-boot settings) | 8.0–8.7 s |
| `GceEventReporter: VIRTUAL_DEVICE_BOOT_FAILED: Dependencies not ready after 10 checks: Bluetooth` | only without `cuttlefish_service_bluetooth_checker=false` | — |

hvc0 output on VZ starts only when first-stage init has loaded `virtio_pci` and
`virtio_console` (about 0.18 s of uptime), because VZ has no UART for an early
console. The kernel's earlier lines, including `Booting Linux on physical CPU`
and `init: init first stage started!`, are not replayed to hvc0. The first init
line on hvc0 is `init: Loaded kernel module /lib/modules/virtio_pci.ko`. #012 and
#013 base `.kernel` on the first console byte and `.init` on the first `init: `
line ([runtime-daemon.md](runtime-daemon.md) §3.3).

### 7.8 Verification (#095)

Checked 2026-10-09, macOS 27.0.1 (26A434), build 16373615.

- **Ports, test kernel.** `LinuxGuestConsolePortTests.testConsolePortMarkersMatchTheirNumbers` attaches eight ports: `APKRUN-PORT-<i>` arrives on `/dev/hvc<i>` for every `i` from 1 to 7 (identity). The pinned test kernel (Alpine 6.18.54) creates `/dev/hvc0` to `/dev/hvc7` and no more. Twenty ports fail at `/dev/hvc8`, although the guest's virtio-pci probe shows 13 devices. A local run with ten ports failed at the same node (not committed). The 20-port check therefore skips with that reason (IR-371, IR-372).
- **Ports, Android kernel.** The VZ capture of the Android guest lists `/dev/hvc0` to `/dev/hvc19` on the 20-port layout. The holders are the shell on `hvc1`, logcat on `hvc2`, and the HALs on the other numbers (for example `hvc18` and `hvc19` for the sensors and the vendor HALs). No marker test runs on the Android guest, because host input is attached to service ports only.
- **ConsolePortPlan.** The identity mapping needs no reordering on VZ. The plan is a data function with T0 tests, and the boot path does not apply it (IR-373).
- **Security HALs and `/data`.** `testHostServiceSubstitutes` passes: KeyMint and Gatekeeper are registered, `/data` is mounted, and `logcat` has no Weaver timeout or failure line, so LockSettings does not wait for Weaver.
- **Network (open).** On the first boot the first-boot settings run and `cmd wifi connect-network VirtWifi open` logs `Enable disabled network: "VirtWifi"`. `cmd wifi status` then reports `Wifi is disabled`, and `wlan0` (on `buried_eth2`) stays `NO-CARRIER`. No IPv4 address, default route, or DNS follows, and `eth1` and `buried_eth2` have IPv6 addresses only. `dumpsys connectivity` shows validated offers, but name resolution fails (`getent hosts connectivitycheck.gstatic.com` returns nothing). The Wi-Fi state after the first boot is a follow-up (IR-374).
- **Name-service tools on the stock image (2026-10-10).** The `system_a` partition of build 16373615 (`super.img` in the build's download zip, read with the `liblp` reader of `Images/tools` and a directory walk of its EROFS image) contains `/system/bin/ping`, `ping6`, `ndc`, `toybox`, `toolbox`, `sh`, `dumpsys`, `cmd`, `ip`, `logcat`, and `am`, and links for `getprop`, `nc`, `netstat`, and `ifconfig`. It contains no `getent`, `nslookup`, `dig`, `host`, `resolv`, `route`, `wget`, or `curl`. The guest agreed on the probe boot: `command -v getent` and `command -v nslookup` printed nothing, `command -v ping` printed `/system/bin/ping`, and `ls -l /system/bin/ping` reported 68424 bytes, the size in the image. Of the candidates, only `ping` reports a name-resolution result: `ndc resolver` printed nothing as the shell (and `500 0 Command not recognized` as root), `getprop | grep -i dns` printed only `[init.svc.mdnsd]: [running]` (no DNS property), and `dumpsys dnsresolver` printed `Can't find service: dnsresolver` (probes 1 and 6), which the shell's denied service lookup causes (the resolver path below).
- **DNS probe on the stock image (2026-10-10).** On the probe boot (a temporary test, not committed), `ping -c 1 -W 2 connectivitycheck.gstatic.com 2>&1` printed `ping: unknown host connectivitycheck.gstatic.com` and exited 2, as the shell user and as root (`su 0`). `ping -c 1 -W 2 no-such-host.invalid` printed `ping: unknown host no-such-host.invalid`. The same boot had `wlan0` at `inet 192.168.64.25/24` and `default via 192.168.64.1 dev wlan0 table 1018`.
- **Network run with the ping check (2026-10-10, commit `806d07a` before the rebase onto main; `ed40540` after it).** `xcodebuild test-without-building` with `-only-test-configuration AndroidNetwork -only-testing:IntegrationTests/AndroidNetworkTests`, under `lockf -k /tmp/apkrun-vm.lock`, once. The test failed in 139.95 s with one failed assertion: `connectivitycheck.gstatic.com resolves: ping: unknown host connectivitycheck.gstatic.com`. The stage ran in the serial shell, so that failure is the shell's (the resolver path below). The other three stages passed on their last values: the `inet 192.168.64.25/24` address on `wlan0`, the vmnet default route, and a WIFI `NetworkAgentInfo` line with the `VALIDATED` capability and a `firstValidated` time. The validated line of the record shows `DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ]` for the same network.
- **Resolver path (2026-10-10, probe boots under `lockf`; cause in IR-555).**
  - *Ping by address.* `ping -c 1 -W 2 192.168.64.1` and `ping6 -c 1 -W 2 fe80::fcb2:14ff:feba:7a64%wlan0`, the two servers of the LinkProperties line, each printed `100% packet loss`. ICMP gets no reply through vmnet, so ping says nothing about DNS.
  - *UDP DNS.* A hand-built A query for `connectivitycheck.gstatic.com`, sent from the guest with `toybox nc -u`, got an answer from both servers. `192.168.64.1` returned RCODE 0 with `142.251.150.120`, and so did `fe80::fcb2:14ff:feba:7a64%wlan0` (`nc -6`). The control `8.8.8.8` also answered.
  - *Host.* `dig @192.168.64.1 connectivitycheck.gstatic.com A` returned `NOERROR` with `142.251.150.120` in 1 to 6 ms, and so did `dig @fe80::fcb2:14ff:feba:7a64%bridge100`. `dig +tcp` to `192.168.64.1` reported `communications error ... end of file`, so the vmnet server answers UDP.
  - *Configuration.* `net.dns1` to `net.dns4` are empty, `settings get global private_dns_mode` is `null`, `/etc/resolv.conf` does not exist, and `Active default network: 100`. The resolver logs `resolv_set_nameservers: netid = 100` for `192.168.64.1` and for `fe80::fcb2:14ff:feba:7a64%wlan0`.
  - *Other uids.* NetworkMonitor (uid 1000) logs `PROBE_DNS connectivitycheck.gstatic.com 9ms OK 142.251.150.120` and `PROBE_HTTP ... ret=204`. App uids 10029, 10066, and 10111 each get `doQuery: rcode=0` answers through netid 100.
  - *Shell and root.* The serial shell runs as `uid=2000(shell)` in `u:r:shell:s0`. `toybox nc -U /dev/socket/dnsproxyd` printed `nc: connect: Permission denied`, and `ls -lZ /dev/socket/dnsproxyd` printed `Permission denied`. The shell's lookups fail at once: `ping` printed `unknown host` (elapsed 0), and `toybox nc -z` printed `No address associated with hostname` (elapsed 0). No resolver log line has uid 2000. Root (`u:r:su:s0`) connects (`status=0`), and `su 0 ping -c 1 -W 2 connectivitycheck.gstatic.com` printed `PING connectivitycheck.gstatic.com (142.251.150.120) 56(84) bytes of data.` with `elapsed=2`.
  - *Services.* The earlier reading that the resolver was absent was wrong. `service list` registers `dnsresolver: []` and `netd: []`, and `init.svc.netd` is `running`. `dumpsys dnsresolver` (probe 6) and `dumpsys netd` (probe 5) print `Can't find service` because the shell is denied the lookup: `avc: denied { find } ... uid=2000 name=dnsresolver scontext=u:r:shell:s0 ... tclass=service_manager permissive=0`. The log has no AVC line for the DNS-proxy connect, so SELinux and socket permissions are not separated.
  - *Result.* The DNS failure is the shell's: its user cannot reach the resolver. The network and the resolver work for root, for NetworkMonitor, and for app uids. The image's SELinux policy belongs to #035 (§7.8 and §11).
- **Network run with the DNS stage as root (2026-10-10, commit `11f93c7` before the rebase onto main; `c839ef8` after it).** `AndroidNetwork`, `testNetwork`, once, under `lockf`: passed in 23.643 s with no failures. The `resolved:` line of the record is `PING connectivitycheck.gstatic.com (142.251.150.120) 56(84) bytes of data.`, and the `validated:` line is a WIFI `NetworkAgentInfo` with the `&VALIDATED&` capability and no `NOT_VALIDATED`. This root run came before the five runs of the next bullet, and before the rebase onto main.

- **Five runs of the network check (2026-10-10, commit `c839ef8` on main `eaa0fd5`).** `xcodebuild test-without-building -only-test-configuration AndroidNetwork -only-testing:IntegrationTests/AndroidNetworkTests/testNetwork`, five times in a row under `lockf -k /tmp/apkrun-vm.lock`, one boot each. All five passed all four stages. Each run's `resolved:` line is `PING connectivitycheck.gstatic.com (142.251.150.120) 56(84) bytes of data.`, each has `inet 192.168.64.25/24` on `wlan0`, and each has `default via 192.168.64.1 dev wlan0 table 1018`. After each run, `ls -d /tmp/apkrun-vm-*` found no home.

| Run | Result | Test time | Wall time (JST) | `firstValidated` = `lastValidated` |
|---|---|---|---|---|
| 1 | passed | 24.234 s | 21:43:03 to 21:43:47 | 15462 |
| 2 | passed | 23.896 s | 21:43:54 to 21:44:38 | 15165 |
| 3 | passed | 22.312 s | 21:44:43 to 21:45:26 | 15317 |
| 4 | passed | 24.058 s | 21:45:31 to 21:46:14 | 15061 |
| 5 | passed | 27.163 s | 21:46:19 to 21:47:07 | 17370 |

The `validated:` line of each run, exactly as the record prints it. Each has the capability `&VALIDATED&`, and none has `NOT_VALIDATED`:

```text
run 1: validated: NetworkAgentInfo{network{100}  handle{432902426637}  ni{WIFI CONNECTED extra: } created=2026-10-10T12:43:41.743Z Score(Policies : TRANSPORT_PRIMARY&EVER_EVALUATED&IS_UNMETERED&EVER_USER_SELECTED&EVER_VALIDATED&IS_VALIDATED ; KeepConnected : 0)  created 15311 firstValidated 15462 lastValidated 15462 explicitlySelected  lp{{InterfaceName: wlan0 LinkAddresses: [ fe80::15:b2ff:fe00:0/64,192.168.64.25/24,fdc5:9ff7:f720:e037:15:b2ff:fe00:0/64,fdc5:9ff7:f720:e037:2f22:82f7:72e:4633/64 ] DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ] Domains: zelda.nintendo.co.jp MTU: 0 ServerAddress: /192.168.64.1 TcpBufferSizes: 524288,1048576,2097152,262144,524288,1048576 Routes: [ fe80::/64 -> :: wlan0 mtu 0,::/0 -> fe80::fcb2:14ff:feba:7a64 wlan0 mtu 0,fdc5:9ff7:f720:e037::/64 -> :: wlan0 mtu 0,192.168.64.0/24 -> 0.0.0.0 wlan0 mtu 0,0.0.0.0/0 -> 192.168.64.1 wlan0 mtu 0 ]}}  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&NOT_ROAMING&FOREGROUND&NOT_CONGESTED&NOT_SUSPENDED&NOT_VCN_MANAGED&NOT_BANDWIDTH_CONSTRAINED LinkUpBandwidth>=12000Kbps LinkDnBandwidth>=60000Kbps Specifier: <WifiNetworkAgentSpecifier [WifiConfiguration=, SSID="VirtWifi", BSSID=a2:6a:5d:b2:f9:0b, band=2, mMatchLocalOnlySpecifiers=false]> TransportInfo: <SSID: "VirtWifi", BSSID: a2:6a:5d:b2:f9:0b, MAC: 02:15:b2:00:00:00, IP: /192.168.64.25, Security type: 0, Supplicant state: COMPLETED, Wi-Fi standard: unknown, RSSI: -50, Link speed: 1Mbps, Tx Link speed: 1Mbps, Max Supported Tx Link speed: -1Mbps, Calculated Tx : 0Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: -1Mbps, Calculated Rx : 0Mbps, Frequency: 5240MHz, Net ID: 0, Metered hint: false, score: 100, isUsable: true, CarrierMerged: false, SubscriptionId: -1, IsPrimary: 1, Trusted: true, Restricted: false, Ephemeral: false, OEM paid: false, OEM private: false, OSU AP: false, FQDN: <none>, Provider friendly name: <none>, Requesting package name: <none>"VirtWifi"openMLO Information: , Is TID-To-Link negotiation supported by the AP: false, AP MLD Address: <none>, AP MLO Link Id: <none>, AP MLO Affiliated links: <none>, Vendor Data: <none>> SignalStrength: -50 OwnerUid: 2000 AdminUids: [2000] SSID: "VirtWifi" UnderlyingNetworks: Null]}  factorySerialNumber=6}
run 2: validated: NetworkAgentInfo{network{100}  handle{432902426637}  ni{WIFI CONNECTED extra: } created=2026-10-10T12:44:33.484Z Score(Policies : TRANSPORT_PRIMARY&EVER_EVALUATED&IS_UNMETERED&EVER_USER_SELECTED&EVER_VALIDATED&IS_VALIDATED ; KeepConnected : 0)  created 15050 firstValidated 15165 lastValidated 15165 explicitlySelected  lp{{InterfaceName: wlan0 LinkAddresses: [ fe80::15:b2ff:fe00:0/64,192.168.64.25/24,fdc5:9ff7:f720:e037:15:b2ff:fe00:0/64,fdc5:9ff7:f720:e037:e947:f1d4:e2d4:7b1e/64 ] DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ] Domains: zelda.nintendo.co.jp MTU: 0 ServerAddress: /192.168.64.1 TcpBufferSizes: 524288,1048576,2097152,262144,524288,1048576 Routes: [ fe80::/64 -> :: wlan0 mtu 0,::/0 -> fe80::fcb2:14ff:feba:7a64 wlan0 mtu 0,fdc5:9ff7:f720:e037::/64 -> :: wlan0 mtu 0,192.168.64.0/24 -> 0.0.0.0 wlan0 mtu 0,0.0.0.0/0 -> 192.168.64.1 wlan0 mtu 0 ]}}  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&NOT_ROAMING&FOREGROUND&NOT_CONGESTED&NOT_SUSPENDED&NOT_VCN_MANAGED&NOT_BANDWIDTH_CONSTRAINED LinkUpBandwidth>=12000Kbps LinkDnBandwidth>=60000Kbps Specifier: <WifiNetworkAgentSpecifier [WifiConfiguration=, SSID="VirtWifi", BSSID=12:4a:16:17:b6:ef, band=2, mMatchLocalOnlySpecifiers=false]> TransportInfo: <SSID: "VirtWifi", BSSID: 12:4a:16:17:b6:ef, MAC: 02:15:b2:00:00:00, IP: /192.168.64.25, Security type: 0, Supplicant state: COMPLETED, Wi-Fi standard: unknown, RSSI: -50, Link speed: 1Mbps, Tx Link speed: 1Mbps, Max Supported Tx Link speed: -1Mbps, Calculated Tx : 0Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: -1Mbps, Calculated Rx : 0Mbps, Frequency: 5240MHz, Net ID: 0, Metered hint: false, score: 100, isUsable: true, CarrierMerged: false, SubscriptionId: -1, IsPrimary: 1, Trusted: true, Restricted: false, Ephemeral: false, OEM paid: false, OEM private: false, OSU AP: false, FQDN: <none>, Provider friendly name: <none>, Requesting package name: <none>"VirtWifi"openMLO Information: , Is TID-To-Link negotiation supported by the AP: false, AP MLD Address: <none>, AP MLO Link Id: <none>, AP MLO Affiliated links: <none>, Vendor Data: <none>> SignalStrength: -50 OwnerUid: 2000 AdminUids: [2000] SSID: "VirtWifi" UnderlyingNetworks: Null]}  factorySerialNumber=7}
run 3: validated: NetworkAgentInfo{network{100}  handle{432902426637}  ni{WIFI CONNECTED extra: } created=2026-10-10T12:45:22.613Z Score(Policies : TRANSPORT_PRIMARY&EVER_EVALUATED&IS_UNMETERED&EVER_USER_SELECTED&EVER_VALIDATED&IS_VALIDATED ; KeepConnected : 0)  created 15180 firstValidated 15317 lastValidated 15317 explicitlySelected  lp{{InterfaceName: wlan0 LinkAddresses: [ fe80::15:b2ff:fe00:0/64,192.168.64.25/24,fdc5:9ff7:f720:e037:15:b2ff:fe00:0/64,fdc5:9ff7:f720:e037:4c96:7eee:52e5:7ca/64 ] DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ] Domains: zelda.nintendo.co.jp MTU: 0 ServerAddress: /192.168.64.1 TcpBufferSizes: 524288,1048576,2097152,262144,524288,1048576 Routes: [ fe80::/64 -> :: wlan0 mtu 0,::/0 -> fe80::fcb2:14ff:feba:7a64 wlan0 mtu 0,fdc5:9ff7:f720:e037::/64 -> :: wlan0 mtu 0,192.168.64.0/24 -> 0.0.0.0 wlan0 mtu 0,0.0.0.0/0 -> 192.168.64.1 wlan0 mtu 0 ]}}  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&NOT_ROAMING&FOREGROUND&NOT_CONGESTED&NOT_SUSPENDED&NOT_VCN_MANAGED&NOT_BANDWIDTH_CONSTRAINED LinkUpBandwidth>=12000Kbps LinkDnBandwidth>=60000Kbps Specifier: <WifiNetworkAgentSpecifier [WifiConfiguration=, SSID="VirtWifi", BSSID=8e:0c:36:7f:6c:ea, band=2, mMatchLocalOnlySpecifiers=false]> TransportInfo: <SSID: "VirtWifi", BSSID: 8e:0c:36:7f:6c:ea, MAC: 02:15:b2:00:00:00, IP: /192.168.64.25, Security type: 0, Supplicant state: COMPLETED, Wi-Fi standard: unknown, RSSI: -50, Link speed: 1Mbps, Tx Link speed: 1Mbps, Max Supported Tx Link speed: -1Mbps, Calculated Tx : 0Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: -1Mbps, Calculated Rx : 0Mbps, Frequency: 5240MHz, Net ID: 0, Metered hint: false, score: 100, isUsable: true, CarrierMerged: false, SubscriptionId: -1, IsPrimary: 1, Trusted: true, Restricted: false, Ephemeral: false, OEM paid: false, OEM private: false, OSU AP: false, FQDN: <none>, Provider friendly name: <none>, Requesting package name: <none>"VirtWifi"openMLO Information: , Is TID-To-Link negotiation supported by the AP: false, AP MLD Address: <none>, AP MLO Link Id: <none>, AP MLO Affiliated links: <none>, Vendor Data: <none>> SignalStrength: -50 OwnerUid: 2000 AdminUids: [2000] SSID: "VirtWifi" UnderlyingNetworks: Null]}  factorySerialNumber=6}
run 4: validated: NetworkAgentInfo{network{100}  handle{432902426637}  ni{WIFI CONNECTED extra: } created=2026-10-10T12:46:08.362Z Score(Policies : TRANSPORT_PRIMARY&EVER_EVALUATED&IS_UNMETERED&EVER_USER_SELECTED&EVER_VALIDATED&IS_VALIDATED ; KeepConnected : 0)  created 14923 firstValidated 15061 lastValidated 15061 explicitlySelected  lp{{InterfaceName: wlan0 LinkAddresses: [ fe80::15:b2ff:fe00:0/64,192.168.64.25/24,fdc5:9ff7:f720:e037:15:b2ff:fe00:0/64,fdc5:9ff7:f720:e037:5d8e:aafa:bc24:2e65/64 ] DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ] Domains: zelda.nintendo.co.jp MTU: 0 ServerAddress: /192.168.64.1 TcpBufferSizes: 524288,1048576,2097152,262144,524288,1048576 Routes: [ fe80::/64 -> :: wlan0 mtu 0,::/0 -> fe80::fcb2:14ff:feba:7a64 wlan0 mtu 0,fdc5:9ff7:f720:e037::/64 -> :: wlan0 mtu 0,192.168.64.0/24 -> 0.0.0.0 wlan0 mtu 0,0.0.0.0/0 -> 192.168.64.1 wlan0 mtu 0 ]}}  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&NOT_ROAMING&FOREGROUND&NOT_CONGESTED&NOT_SUSPENDED&NOT_VCN_MANAGED&NOT_BANDWIDTH_CONSTRAINED LinkUpBandwidth>=12000Kbps LinkDnBandwidth>=60000Kbps Specifier: <WifiNetworkAgentSpecifier [WifiConfiguration=, SSID="VirtWifi", BSSID=9a:bb:a4:91:56:3c, band=2, mMatchLocalOnlySpecifiers=false]> TransportInfo: <SSID: "VirtWifi", BSSID: 9a:bb:a4:91:56:3c, MAC: 02:15:b2:00:00:00, IP: /192.168.64.25, Security type: 0, Supplicant state: COMPLETED, Wi-Fi standard: unknown, RSSI: -50, Link speed: 1Mbps, Tx Link speed: 1Mbps, Max Supported Tx Link speed: -1Mbps, Calculated Tx : 0Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: -1Mbps, Calculated Rx : 0Mbps, Frequency: 5240MHz, Net ID: 0, Metered hint: false, score: 100, isUsable: true, CarrierMerged: false, SubscriptionId: -1, IsPrimary: 1, Trusted: true, Restricted: false, Ephemeral: false, OEM paid: false, OEM private: false, OSU AP: false, FQDN: <none>, Provider friendly name: <none>, Requesting package name: <none>"VirtWifi"openMLO Information: , Is TID-To-Link negotiation supported by the AP: false, AP MLD Address: <none>, AP MLO Link Id: <none>, AP MLO Affiliated links: <none>, Vendor Data: <none>> SignalStrength: -50 OwnerUid: 2000 AdminUids: [2000] SSID: "VirtWifi" UnderlyingNetworks: Null]}  factorySerialNumber=7}
run 5: validated: NetworkAgentInfo{network{100}  handle{432902426637}  ni{WIFI CONNECTED extra: } created=2026-10-10T12:47:00.624Z Score(Policies : TRANSPORT_PRIMARY&EVER_EVALUATED&IS_UNMETERED&EVER_USER_SELECTED&EVER_VALIDATED&IS_VALIDATED ; KeepConnected : 0)  created 17231 firstValidated 17370 lastValidated 17370 explicitlySelected  lp{{InterfaceName: wlan0 LinkAddresses: [ fe80::15:b2ff:fe00:0/64,192.168.64.25/24,fdc5:9ff7:f720:e037:15:b2ff:fe00:0/64,fdc5:9ff7:f720:e037:9b11:4f27:6af5:911b/64 ] DnsAddresses: [ /fe80::fcb2:14ff:feba:7a64%wlan0,/192.168.64.1 ] Domains: zelda.nintendo.co.jp MTU: 0 ServerAddress: /192.168.64.1 TcpBufferSizes: 524288,1048576,2097152,262144,524288,1048576 Routes: [ fe80::/64 -> :: wlan0 mtu 0,::/0 -> fe80::fcb2:14ff:feba:7a64 wlan0 mtu 0,fdc5:9ff7:f720:e037::/64 -> :: wlan0 mtu 0,192.168.64.0/24 -> 0.0.0.0 wlan0 mtu 0,0.0.0.0/0 -> 192.168.64.1 wlan0 mtu 0 ]}}  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED&NOT_ROAMING&FOREGROUND&NOT_CONGESTED&NOT_SUSPENDED&NOT_VCN_MANAGED&NOT_BANDWIDTH_CONSTRAINED LinkUpBandwidth>=12000Kbps LinkDnBandwidth>=60000Kbps Specifier: <WifiNetworkAgentSpecifier [WifiConfiguration=, SSID="VirtWifi", BSSID=66:6e:21:e2:48:d9, band=2, mMatchLocalOnlySpecifiers=false]> TransportInfo: <SSID: "VirtWifi", BSSID: 66:6e:21:e2:48:d9, MAC: 02:15:b2:00:00:00, IP: /192.168.64.25, Security type: 0, Supplicant state: COMPLETED, Wi-Fi standard: unknown, RSSI: -50, Link speed: 1Mbps, Tx Link speed: 1Mbps, Max Supported Tx Link speed: -1Mbps, Calculated Tx : 0Mbps, Rx Link speed: -1Mbps, Max Supported Rx Link speed: -1Mbps, Calculated Rx : 0Mbps, Frequency: 5240MHz, Net ID: 0, Metered hint: false, score: 100, isUsable: true, CarrierMerged: false, SubscriptionId: -1, IsPrimary: 1, Trusted: true, Restricted: false, Ephemeral: false, OEM paid: false, OEM private: false, OSU AP: false, FQDN: <none>, Provider friendly name: <none>, Requesting package name: <none>"VirtWifi"openMLO Information: , Is TID-To-Link negotiation supported by the AP: false, AP MLD Address: <none>, AP MLO Link Id: <none>, AP MLO Affiliated links: <none>, Vendor Data: <none>> SignalStrength: -50 OwnerUid: 2000 AdminUids: [2000] SSID: "VirtWifi" UnderlyingNetworks: Null]}  factorySerialNumber=7}
```

---

## 8. Reference boot capture (#064)

The reference boot is ground truth for everything that U-Boot and the Cuttlefish launcher normally do. Every VZ boot difference must be explained.

### 8.1 Reference host

In order of preference:

1. An arm64 Linux machine (bare metal or cloud), with `/dev/kvm`.
2. An x86-64 Linux host running the arm64 image under QEMU TCG. It is slow, but acceptable for a one-time capture.

The reference host installs the Cuttlefish host tools (`cvd`, from the android-cuttlefish packages for arm64) and the same image build (§2).

**The nested-virtualization VM is not a usable reference host.** It was the first choice: an arm64 Linux VM with nested virtualization on an M3-or-later Mac (`VZGenericPlatformConfiguration.isNestedVirtualizationEnabled`). From 2026-09-30 to 2026-10-09, 62 captures on a Lima VM of that kind never reached `sys.boot_completed=1`. The guest ran about 100 times slower than the same image booted directly on VZ: `zygote` started at 233 s of uptime against 1.3 s, and `boot_progress_pms_ready` came at 1467 s against 3.6 s. `system_server` was then killed by its Watchdog during startup (IR-279, IR-305). The project has no arm64 Linux machine, so no complete reference boot exists. What the captures do provide is kept as the reference for launcher outputs: the `internal/bootconfig`, the kernel command line, the composite disk layout, `cuttlefish_config.json`, and the kernel log up to `system_server`. The `incomplete/` records under `Images/reference/16373615/` hold them. Behaviour that needs a booted reference comes from the Cuttlefish source at the pinned revision (`android17-release`) and from the VZ boot itself. #064 is re-scoped accordingly (IR-305).

### 8.2 Profiles

| Profile | `launch_cvd` flags | Purpose |
|---|---|---|
| `default` | defaults, `--cpus 4 --memory_mb 4096` | how stock Cuttlefish really boots |
| `target` | `--gpu_mode=drm_virgl --secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure --cpus 4 --memory_mb 4096` | the configuration APKRun reproduces on VZ |
| `swiftshader` | `--gpu_mode=guest_swiftshader` + the `target` HAL flags | the fallback GPU profile ([graphics.md](graphics.md) §9) |

The `target` profile defaults to `drm_virgl`. If the reference host cannot
run it (it needs host virglrenderer with EGL; Mesa llvmpipe may be enough),
the operator must explicitly select the `guest_swiftshader` fallback using
the environment variables in §8.3. The fallback records its source-derived
`drm_virgl` properties separately.
For `target` with `drm_virgl`, `capture.sh` sets the host
`EGL_PLATFORM=surfaceless` before both CVD commands and records
`eglPlatform=surfaceless` in `host.json`. For all other profile and GPU-mode
combinations, `capture.sh` clears any inherited `EGL_PLATFORM` and records
`eglPlatform=null`.
For the reference capture, `capture.sh` passes the profile's `--gpu_mode` to
both group creation and named-group start. Cuttlefish may select its default
again at start, so `targetGpuMode` in `host.json` is only the requested mode;
profile comparisons use `selectedGpuMode` from the selected instance config.
For all three profiles, `capture.sh` also passes
`--gpu_vhost_user_mode=off` to both commands and requires the selected config
to record `enable_gpu_vhost_user=false`. Cuttlefish 1.57.0 auto-enables its
vhost-user GPU backend on arm64, where `drm_virgl` is not supported by that
backend. `host.json` records the observed value as `gpuVhostUserEnabled`.

The pinned Cuttlefish 1.57.0 crosvm build used by the tested host package
disables default Cargo features and enables `gfxstream` and `gpu`, but omits
`virgl_renderer`. That crosvm feature enables `devices/virgl_renderer`.
Selecting `backend=virglrenderer` with the feature disabled makes Rutabaga
return `invalid rutabaga build parameters` before guest kernel output.
Installing the host `libvirglrenderer` library does not enable this crosvm
build feature. A `drm_virgl` reference capture therefore requires a Cuttlefish
host package whose pinned crosvm build enables `virgl_renderer`; see
[IR-171](../04-plan/implementation-review.md#ir-171-diagnose-crosvm-panic-output).

### 8.3 What is captured

`Images/tools/reference/capture.sh <profile>` writes `Images/reference/<buildId>/<profile>/`:

| Host side | Guest side (via `adb`) |
|---|---|
| crosvm command line (from `launcher.log` / `ps -ww`) | `/proc/cmdline`, `/proc/bootconfig` |
| `host.json` crosvm command/executable and adjacent gfxstream ELF identities | |
| `cuttlefish_runtime/internal/bootconfig` (AVB footer stripped) | `getprop` (all) |
| composite disk specs (`ap`, `os`, and persistent composite config files) | `ls -l /dev/block/by-name/`, `readlink -f /sys/block/vd*`, `lsblk` equivalent from sysfs |
| `cuttlefish_config.json` | `/proc/mounts`, `/vendor/etc/fstab.*` |
| `assemble_cvd.log`, `kernel.log`, `launcher.log`, `host-logcat.txt` | `dmesg`, `lsmod`, first-stage init log lines |
| | `ls -l /dev/hvc*` and which process holds each (`/proc/*/fd`) |
| | `logcat -d -b all` (gzip), `lshal`, `service list`, `ls /apex`, `pm list features` |
| | `ip addr`, `ip route`, `ip link`, `dumpsys connectivity` summary |
| | `/proc/asound/cards`, `getenforce`, AVC denials |
| | `VIRTUAL_DEVICE_*` markers with timestamps |

Instance numbering and ADB port selection follow the
[Cuttlefish multi-tenancy documentation](https://source.android.com/docs/devices/cuttlefish/multi-tenancy).

`capture.sh` runs only on Linux with Python 3.12 from `Images/tools/.venv`. It
requires the extracted guest image directory in `ANDROID_PRODUCT_OUT`, verifies
all artifacts against the checked-in build 16373615 manifest, and uses
`launch_cvd`, `stop_cvd`, and `adb` from the matching Cuttlefish host tools on
`PATH`. The host must have no ADB devices or crosvm processes attached, and
only one reference profile can capture at a time. It uses Cuttlefish instance
1 by default, or accepts `APKRUN_CVD_INSTANCE_NUM` for another provisioned
number. Each run gets a private temporary Cuttlefish `HOME`, which isolates
its runtime files and instance group from other Cuttlefish sessions. Guest
commands are sent only to the `localhost` or `127.0.0.1` ADB serial for that
instance's port; network ADB devices are not selected. Shutdown runs in the
same private `HOME`, which contains only the one instance group created by
this run. Host artifacts are read only from the instance directory resolved
from its `cuttlefish_runtime` link (the link points directly to
`instances/cvd-<n>/`). The private `HOME` is removed after a successful
shutdown. If launch fails, cleanup still targets that private group; the
directory is preserved with its path printed only if shutdown or removal
fails. A host-wide lock under `/tmp` serializes
captures across checkouts on the host, so only one profile capture can run at
a time. Shutdown is bounded by
`APKRUN_CVD_STOP_TIMEOUT_SECONDS` (120 seconds by default, followed by a
10-second forced-stop grace period).

Both `cvd create --nostart` and named-group `cvd start` run through
`capture_cvd_start.py` under the remaining shared boot deadline. While either
command runs, the helper schedules `cvd logs --nopretty` polls 0.5 seconds
apart from each poll's start time and atomically snapshots
`assemble_cvd.log`, `kernel.log`, and `launcher.log` into the private staging
directory. Each live snapshot is limited to 64 MiB, accepts only regular files
beneath the private Cuttlefish `HOME`, and remains available if Cuttlefish
deletes its runtime logs during shutdown. Host `logcat` is excluded from live
polling because it can grow quickly. After the CVD command returns, artifact
collection takes one bounded, atomic snapshot of the selected instance's
`logcat`, when available. The snapshot is renamed to `host-logcat.txt` before
normalization. If it exceeds the cap, the retained tail starts at a complete
line boundary. An absent or unsafe logcat is recorded in `MISSING.txt`; an
artifact that cannot be safely normalized is discarded and also leaves the
capture incomplete. Each live-polled log name is attempted at most once per
listing poll after its path is validated as a regular file beneath the private
HOME. Invalid duplicate rows cannot suppress a later valid path or trigger
repeated full-file copies.
The listing parser preserves spaces in paths and accepts either a bare log
name or a group and instance prefix such as
`<group>:<instance>:kernel.log`. It matches only a known final log name and
still requires an absolute regular file whose resolved path is beneath the
private HOME. If listing takes longer than 0.5 seconds, the helper starts the
next poll as soon as listing returns, and a malformed log listing does not
prevent it from terminating the CVD process group.
For a long `cvd start`, setting `APKRUN_CAPTURE_BOOT_OBSERVER=1` also writes
`boot-observer.jsonl` while the command is running. An independent sampler
checks the Android crosvm every five seconds. It wakes on a one-second
schedule to rescan the launcher log for event 5 and complete ADB connector
attempts. RSS measurements retain their five-second interval. The ADB
observer starts when either a complete, source-qualified connector attempt or
event 5 is observed, without waiting for the next RSS sample. Event 5 wakes the
existing ADB thread for an immediate poll except during the reserved final
probe window, when regular polling stays paused to protect the capture
deadline. Launcher
lines identify their emitting process by name and PID. The observer collects
`process_restarter` PIDs directly from those prefixes, then accepts only a
process whose executable and command line identify the private instance,
include Android's `kernel-log-pipe` serial, and exclude the OpenWrt serial.
This avoids pairing interleaved `Started` lines with arguments. The sampler
reads the selected restarter's direct child, confirms the child's procfs
parent PID is that restarter, and rechecks both processes' pinned start times
before recording `VmRSS` and `RssShmem`. It requires the staged crosvm path
and verifies that
`/proc/<pid>/exe` refers to the same file, even when the staged path is a
symlink. Ambiguous or mismatched process identities are not sampled. Resolve
the private HOME's `cuttlefish_runtime` link during sampling because Cuttlefish
may create it only after `cvd start` begins. The link points into
Cuttlefish-managed storage outside the private HOME, so validate its direct
target as `/var/tmp/cvd/<current-uid>/<run>/home/cuttlefish/instances/cvd-<n>`.
Resolve that path through Cuttlefish's symlink chain and require its
destination to be exactly the matching `cuttlefish/instances/cvd-<n>` beneath
this capture's private HOME. This accepts the normal managed `home` link and
rejects redirected `home` or `instances` components. The instance number must
match the selected ADB port. Pin the first valid target; record a pending
event while the link is absent, a discovered event when it resolves, and a
failure if it never resolves. If the target changes, clear process identity
and record an observation gap rather than switching instances.
`capture_cvd_start.py` atomically replaces the launcher-log snapshot, so inode
identity is not used to detect a new generation. The observer checks the
initial prefix and bytes around the last consumed offset; if the bounded
snapshot is truncated or those bytes change, it clears prior process
identities and records an observation gap.
Launcher lines are capped at 64 KiB. If a line exceeds the cap across reads,
the observer discards its remainder through the next newline before parsing
again, so a continuation cannot be treated as a new record. A disappeared,
inaccessible, non-regular, or over-cap snapshot clears candidate process
identities and connector counts and marks an observation gap.
The observer also classifies complete `adb_connector` launcher lines into
`connectAttempts`, `connectMessagesSent`, `deviceNotFoundResponses`, and
`disconnectRequests`, then emits one `cuttlefish_adb_connector_summary` record
during observer shutdown. The summary stores no connector PID, device serial,
address, or raw log line. `launcherLogObserved`,
`launcherLogGapDetected`, and `partialLauncherLineAtStop` describe whether a
valid launcher snapshot was read, whether the observer detected a gap, and
whether a partial line remained at shutdown. These counts describe only
Cuttlefish's own logged connector messages. `connectMessagesSent` reflects
Cuttlefish logging that a message was sent; it does not establish ADB device
readiness. This passive summary runs even when launcher event 5 is absent.
The private ADB observer starts after either the first complete,
source-qualified `adb_connector` connection-attempt line or the complete,
source-qualified `socket_vsock_proxy` event 5 line. It uses a 60-second
schedule before event 5. Event 5 remains a separate marker and wakes the
existing observer thread for an immediate poll outside the reserved final
probe window; the thread and private server are not started twice. Polls use
the selected instance's loopback serial and the observer's private ADB socket.
Shell diagnostics run only after `get-state` reports `device`. A connector
attempt, event 5, or ADB `device` state does not establish Android boot
completion.
When `APKRUN_CROSVM_BINARY` selects a diagnostic command, the capture passes
that command path to the observer so it checks the basename requested by
`process_restarter` under the validated private instance. It preserves the
supplied command basename, including when the override is a symlink, and
resolves the executable target separately. A launcher wrapper that executes
a different crosvm binary can also set
`APKRUN_CROSVM_OBSERVER_EXECUTABLE`; the observer then checks the child's
`argv[0]` against the staged command or the known command/executable paths,
and verifies `/proc/<pid>/exe` with `samefile` against the expected
executable. It retains the private-instance check on the wrapper request.
Both paths stay in memory and are not written to observer records.
Before launcher log event 5, it probes the selected localhost ADB serial on a
monotonic 60-second schedule through a private ADB server socket. Event 5
wakes that same observer thread immediately outside the final probe window;
subsequent regular polls use a monotonic 15-second schedule. During the
reserved final window, the observer skips regular shell and property polls and
preserves its bounded final state and logcat probe. It records only bounded
state fields, including the numeric `systemServerStartCount`,
the nullable Boolean `systemServerStartCountPresent`, the nullable Boolean
`sysBootCompletedPresent`, and the nullable Boolean `sysBootCompleted`
signal. A successful, non-empty `sys.system_server.start_count` sets its
presence field even if its value is not a bounded integer. A successful,
non-empty `sys.boot_completed` sets its presence field even if its value is
not `0` or `1`; only `0` and `1` produce a Boolean signal. Failed or
unobserved queries leave the corresponding presence and value fields null.
The shell query replaces non-digit `start_count` values and `boot_completed`
values other than empty, `0`, or `1` with a fixed marker, preventing property
contents from injecting protocol lines. It appends each getprop exit status
with a non-newline delimiter before command substitution, preserving trailing
property newlines; it removes only the single newline emitted by getprop
before validation. The shell reads `sys.boot_completed` first and emits its
sanitized value and exit status before querying `sys.system_server.start_count`.
A later timeout therefore preserves an already completed boot-property query.
The parser accepts LF and CRLF transport line endings,
removing one carriage return only when it is immediately before a line feed,
then requires the fixed order `boot_completed`,
`boot_completed_status`, `system_server`, `system_server_status`. During a
command timeout only, the parser ignores a final unterminated fragment when
it is a prefix of the next expected field label, retaining earlier complete
property pairs. Complete malformed or out-of-order lines still invalidate
the reply. An unterminated final carriage return is preserved. Because the
shell has already reduced property values to ASCII digits or a fixed marker,
removing one carriage return before each line feed cannot turn a raw property
value into an accepted value.
The bounded ADB subprocess runner passes the property reply and any partial
timeout output to this parser without trimming; only the separate `get-state`
response is whitespace-normalized. A property reply is not parsed when its
output was truncated, its probe failed, or its process-group cleanup could not
be verified.
Unexpected, duplicate, empty interior, or
out-of-order lines invalidate the entire parsed reply, including exit
statuses. Both properties are read by one shell command capped at ten
seconds, and each property's bounded exit status is recorded separately as
`systemServerGetpropExitCode` and `bootCompletedGetpropExitCode`, so a
successful query remains distinguishable from a failed query even though the
enclosing shell command ends with a status-printing command. A partial result
remains usable if the other query fails. Raw ADB output, including partial
output from a timed-out command, is parsed in memory and never stored. Each
`adb_poll` record includes
`getpropAttempted` and nullable `getpropTimedOut` fields, so a deadline
reached before the property query is distinguishable from a query that ran
and timed out. It records `connectAttempted`, `connectExitCode`, and nullable
`connectTimedOut` separately from `getStateAttempted`, `getStateExitCode`,
and nullable `getStateTimedOut`. A stage that did not start has a null exit
code and timeout field. `getStateResult` contains only an allowlisted
classification: `notAttempted`, `timedOut`, `commandFailed`, `device`,
`offline`, `unauthorized`, `empty`, `other`, or `probeError`; a probe error
never yields an accepted `deviceState`. Raw command output is never stored.
The observer also records `getpropOutputBytes`, the bounded response byte
count, and nullable `getpropOutputParsed`. The latter is true when the parser
recognizes at least one expected response field, false when it recognizes
none, and null when parsing is skipped or the query did not run. Interpret it
with `getpropAttempted`, `getpropTruncated`, `getpropProbeError`, and the
per-property fields: the byte count distinguishes an empty response from a
non-empty unrecognized response, while a parsed response with a false
`sysBootCompletedPresent` or `systemServerStartCountPresent` indicates an
empty property value. These diagnostics retain no raw response content.
If a property query times out, keep the current phase's ADB transport polling
schedule (60 seconds before event 5, 15 seconds after event 5) but defer the
next property shell query for 30 seconds; after a
second consecutive timeout, defer it for 60 seconds, capped at 60 seconds
until a property command returns without timing out. The `getpropRetryInSeconds`
field records the selected delay on a timeout and the rounded-up remaining
delay on polls skipped by this backoff. A returned property command clears the
backoff and restores property queries to the regular poll schedule. This
reduces repeated guest shell launches while preserving frequent ADB transport
checks. The delay sets the earliest eligible property poll. When ordinary
polling continues and `get-state` reports `device`, the query runs on the first
scheduled poll at or after that delay, after that poll's `connect` and
`get-state` commands complete; those command durations and scheduler delays
add to the actual query time. Each property command remains subject to the
existing ten-second cap. An offline or unavailable ADB state delays the query
until a later eligible poll. The reserved final logcat-probe window also
pauses ordinary property polls and may supersede a pending retry.
The aggregate `commandTimedOut` field reports whether an ADB
subprocess timed out;
`pollDeadlineReached` reports whether the poll reached its shared deadline,
including when that prevented a subprocess from starting. It removes
inherited ADB socket, serial, and vendor-key overrides from the observer
environment. Each stage also records its output-truncation, process-group
cleanup, and probe-error status (`connectTruncated`, `connectCleanupComplete`,
`connectProbeError`, with corresponding `getState` and `getprop` fields).
Aggregate `cleanupComplete` and `probeError` fields summarize those stage
outcomes. Each client runs in its own process group with a 4 KiB stdout cap.
A truncated `connect` reply ends that poll; truncated `get-state` output is
not accepted as a device state, and a truncated property reply is not parsed.
If process-group cleanup cannot be verified, the observer records the
incomplete status, starts no later stage or poll, and fails capture shutdown.
Missed ADB schedule points are skipped rather than replayed.
On the first poll where `get-state` reports `device`, the observer runs a
separate bounded `adb shell sh -c` command in place of that poll's property
query. After its fixed `APKRun shell ready` marker, the command checks
`service check activity`, searches `service list` for the exact `activity`
service entry, and checks `pidof system_server`. It prints only the fixed
classifications `found`, `notFound`, `present`, `notPresent`, or `unknown`;
the raw service output and process ID never leave the guest shell. This
one-shot probe uses the existing ten-second guest-command timeout, 4 KiB
stdout cap, and process-group cleanup bounds, so it does not add to the
regular-poll deadline reserve. The property query resumes on the next
scheduled poll. If the shell-probe process cannot be launched, the one-shot
remains pending for the next eligible poll; after a launched attempt, it is
not retried. `shellProbeMarkerMatched` records whether the command output
began with the marker using LF or CRLF line framing. The strict parser accepts
only complete, ordered, allowlisted result lines and can preserve a valid
prefix when the command times out; it discards an incomplete final line,
malformed replies, truncated output, and output from an unverified process.
The observer retains no raw output. A matched marker confirms that this
standalone shell command returned its marker; an absent marker does not
identify why the command failed to respond. `shellProbeDiagnosticsParsed`
indicates whether at least one complete result line was accepted, and the
`activityServiceCheck`, `activityServiceListed`, and `systemServerProcess`
fields remain null when their results were not captured.
`shellProbeAttempted`, `shellProbeExitCode`, `shellProbeTimedOut`,
`shellProbeTruncated`, `shellProbeCleanupComplete`, and
`shellProbeProbeError` describe the standalone client. The first marker poll
does not issue a property query, so read these fields separately from the
`getprop` fields; subsequent polls run the ordinary property command.
The optional observer also scans atomically replaced `kernel.log` snapshots
for a blocked-state record of `system_server` whose call trace contains
`do_mprotect_pkey`. It reads at most 1 MiB of new log data per scan and
searches all of those bytes together with the retained 256 KiB excerpt before
trimming that excerpt. If it must catch up across more than 1 MiB, it scans
the final 256 KiB and records an observation gap. The log copier passes the
source device, inode, size, and modification time together with each atomic
snapshot. The observer detects inode replacement, truncation, and same-size
modification, and checks the saved prefix and overlap at the previous offset
when the source grows. Growth on a stable inode is treated as append-only;
the upstream [KernelLogServer](https://android.googlesource.com/device/google/cuttlefish/+/refs/heads/main/host/commands/kernel_log_monitor/kernel_log_server.cc)
opens its log with `O_APPEND` and writes each received pipe chunk. Confirm
this behavior against the selected Cuttlefish host package when changing its
version. This avoids rereading the full log on every update. A detected
discontinuity resets the scan and records an observation gap. On a match, it
records the guest uptime and wakes the private ADB observer for an immediate
bounded transport check.
When `get-state` reports `device`, it runs one `su 0 sh -c` command that reads
the state, wait channel, and kernel stack of each current
`/proc/<system_server>/task/*` entry. The thread files are read sequentially,
so this is a bounded best-effort snapshot rather than an atomic capture. A
failed required proc-file read for a task that still exists invalidates the
whole response. A task that exits during collection is skipped, so the
sequential scan can omit threads that disappear while it runs. The command
has a ten-second timeout and a 64 KiB output cap; only a complete, successful
response is parsed. Its
`system_server_thread_snapshot` event keeps thread states, allowlisted
wait-channel text, and kernel function names, while discarding PIDs, TIDs,
thread names, addresses, and raw output. If the guest is unavailable or the
observer reaches its final-probe window first, the event records that the
stack command was not attempted.
The host-side `connect` and `get-state` commands have a two-second cap; the
guest-side shell probe, boot-property query, or thread snapshot has a
ten-second cap. A poll that includes the optional thread snapshot can use
four command caps totaling 24 seconds. Allow up to 2.5 seconds to terminate
and verify each of the four process groups, plus a four-second scheduling
margin, so do not start an ordinary poll during the last 38 seconds before
the final probe.
For a finite capture deadline, leave 40.5 seconds before the ADB polling
cutoff for the final Android logcat probe. Its minimum 39-second budget
covers two two-second host commands, two ten-second logcat queries,
termination and reaping for four ADB client process groups, up to four
seconds for private ADB server shutdown, and a one-second safety margin; the
remaining 1.5 seconds absorb scheduler delay. Do not start an ordinary poll
during the last 38 seconds before that probe. The probe reconnects and checks
`get-state`; only a fresh `device` state permits two bounded queries:
`adb logcat -d -b events -v descriptive -t 128`, followed by
`adb logcat -d -b main -b system -b crash -v brief -t 128`. Each logcat
client has a ten-second timeout and a 64 KiB stdout cap. The `connect` and
`get-state` clients each have a two-second timeout and a 4 KiB stdout cap.
Keep all command output in memory and persist an `adb_logcat_summary` JSONL
event containing only fixed aggregate counts and bounded status fields:
`attempted`, `reason`, `connectExitCode`, `connectTimedOut`,
`connectTruncated`, `connectCleanupComplete`, `connectProbeError`,
`getStateExitCode`, `getStateAttempted`, `getStateTimedOut`,
`getStateTruncated`, `getStateCleanupComplete`, `getStateProbeError`,
`deviceState`, `exitCode`, `timedOut`, `truncated`, `probeError`,
`cleanupComplete`, and `capturedBytes`. Its `summary` contains
integer counts for `recognizedEvents`, `processStartEvents`,
`processExitEvents`, `processCrashEvents`, and `anrEvents`, plus
`systemServerMentionEvents` and `zygoteMentionEvents` and their
`MentionStartEvents`, `MentionExitEvents`, `MentionCrashEvents`,
`MentionAnrEvents`, and `MentionKillEvents` subtotals. Event counters come
only from the events-buffer query. The nested `androidLogcat` object records
`attempted`, `reason`, `exitCode`, `timedOut`, `truncated`, `probeError`,
`cleanupComplete`, and `capturedBytes`, plus a `summary` of line counts
for `fatalExceptionLines`, `fatalSignalLines`, `anrTextLines`,
`watchdogMentionLines`, `systemServerMentionLines`, and
`zygoteMentionLines`. These Android diagnostic counts come only from the
main, system, and crash buffers. They count lines containing fixed markers
or process-name mentions; they do not identify a process targeted by an event,
prove a crash or hang, or establish causation. A timed-out or truncated query
may contribute counts from its captured prefix. Counts contain no guest-log
timestamps or identities. Do not store log payloads, PIDs, UIDs, tags, or
process/package names.
Run each ADB client in its own process group; on a time or output limit,
terminate the group, reap the client, and verify that the group is gone. If
cleanup cannot be confirmed, fail the capture. Observer shutdown allows the
full 40.5-second probe reservation for in-flight clients to finish before
reporting cleanup failure. Captures whose `cvd start` returns before this
final window do not run the probe.
Each ADB command is capped by the remaining time before the 15-second cleanup
reserve, and no following command starts once that boundary is reached. The
mode-0700 socket directory is beneath the run's private HOME.
On Linux, the ADB server receives `SIGKILL` if its observer parent dies,
including when the observer is terminated without running cleanup. Capture
cleanup removes the private HOME and any stale socket path. This opt-in
evidence does not change the launch configuration or the default capture
behavior.
`compare_boot.py` limits plain and compressed inputs, decompressed gzip
content, normalized output, and compressed gzip output to 64 MiB. It preflights
each substitution before allocating an expanded result. Comparison streams
category lines and rejects each capture above 100,000 records or 64 MiB of
normalized key/value text across all categories, bounding comparison maps and
reports. JSON host-path redaction and ambiguous command-line redaction also
enforce the normalized-output limit while building their results. Rules and
expected-difference files must be regular files and are opened without
blocking; reads are limited to 1 MiB. Normalization and comparison reject
capture trees above 100,000 filesystem entries; comparison indexes recognized
category files once before reading them. Complete PEM private-key blocks use a
single linear marker scan with bounded labels.

An abnormal exit normalizes and moves
staging data under `incomplete/`. If raw logcat cannot be removed, the script
tries to discard the whole stage and never publishes it. If the host
filesystem also refuses stage deletion, the script prints the remaining
private staging path for manual cleanup. A profile directory is never
overwritten. Every failed collection is named with a reason in `MISSING.txt`;
an incomplete, normalized capture is moved to
`Images/reference/16373615/incomplete/` and exits nonzero so the canonical
profile can be retried. If normalization fails, raw staging data is never
published; failed stage deletion is reported for manual cleanup.
`host.json` records the host OS, kernel,
architecture, CVD package version and instance number, CPU count,
nested-virtualization availability, and capture duration. It records
`targetGpuMode` as the requested target-profile mode and `selectedGpuMode` as
the actual mode from the selected instance in `cuttlefish_config.json`, along
with `gpuVhostUserEnabled` from that same instance configuration.
Schema version 2 adds `eglPlatform`, which records the host EGL platform
selected for a VirGL target capture.
Schema version 3 adds `hostToolIdentities`, with SHA-256 and GNU ELF Build ID
for the configured crosvm command, its configured expected executable, and
the adjacent `libgfxstream_backend.so` candidate. No absolute host paths are
written. The command may be a diagnostic launcher; the executable is the
value configured by `APKRUN_CROSVM_OBSERVER_EXECUTABLE` or the selected crosvm
binary; this metadata does not verify a running process. The gfxstream entry
is a candidate based on that executable's
directory, not proof that the dynamic loader mapped that file. `status`
distinguishes a complete identity, a missing Build ID, a non-ELF file,
invalid ELF metadata, a file unavailable for reading, and a file changed
during inspection. A SHA-256 is retained when readable even if no Build ID is
available. If any of the three SHA-256 values is unavailable, `capture.sh`
records `host-tool-identities` in `MISSING.txt` and publishes the capture as
incomplete. A missing ELF Build ID alone does not fail identity collection
when SHA-256 is present. The Cuttlefish VCS revision printed as `Launcher
Build ID` is separate from these ELF Build IDs. When the optional boot
observer sees one uniquely verified Android crosvm, it emits one
`crosvm_runtime_identity` event per process generation by identifying
`/proc/<pid>/exe`. The event contains no executable path; the observer verifies
the child and parent process start times, opens the proc executable once, and
hashes through that pinned file descriptor. It checks that descriptor against
the expected ELF and proc link before hashing, then rechecks file metadata,
process generations, and executable identity afterward. A transient unavailable
read is retried up to three times for the same process generation; the final
path-free event records its attempt count. Ambiguous candidates are not hashed,
and failed reads retain a status without an identity. A readable file retains
its SHA-256 even when ELF parsing fails or no GNU Build ID is present; an
unavailable read or rejected process/executable race has no hash.
Compare GPU profiles only when the actual selected mode matches the intended
mode and vhost-user GPU is disabled; a mismatch or missing/invalid setting
keeps the capture incomplete, even when the boot observer collected data
during `cvd start`. The selected instance config is read and copied with a
64 MiB limit.
The JSON parser rejects duplicate keys so an ambiguous selected-instance
configuration cannot validate a profile.

When the host cannot run `drm_virgl`, the `target` fallback is explicit:
`APKRUN_TARGET_GPU_MODE=guest_swiftshader`,
`APKRUN_DRM_VIRGL_SOURCE_REVISION=<revision>`, and
`APKRUN_DRM_VIRGL_PROPS_FILE=<file>` are required. The source-derived graphics
properties are copied into `graphics-props-from-source.txt`; the mode and
revision are recorded in `host.json`.
For Cuttlefish 1.57.0, the GPU-mode properties are constructed by
`CrosvmManager::ConfigureGraphics()` in
[`crosvm_manager.cpp`](https://github.com/google/android-cuttlefish/blob/9bb9c72329cedcb436bb75afc05c24d73fbcdf5d/base/cvd/cuttlefish/host/libs/vm_manager/crosvm_manager.cpp);
`bootconfig_args.cpp` merges those values into the final bootconfig. Record
the exact Cuttlefish revision and derive the `drm_virgl` properties from that
function when using the fallback.
The saved source-derived properties are provenance for the `drm_virgl`
profile. When the selected target mode is `guest_swiftshader`, the guest
bootconfig contains that mode's own graphics properties; do not expect it to
match the separately saved `drm_virgl` property file (see the #064 fallback
record in [IR-173](../04-plan/implementation-review.md#ir-173-swiftshader-target-fallback)).

The host capture also stores `assemble_cvd.log`, `crosvm-command-line.txt`,
`crosvm-runtime-identity.txt` for Virgl runs, `internal-bootconfig.txt` (UTF-8
bootconfig with a valid AVB footer removed), `composite-disk-specs.json`,
`cuttlefish_config.json`, `kernel.log`, `launcher.log`, and `host-logcat.txt`.
While either CVD command runs, live polling snapshots only
`assemble_cvd.log`, `kernel.log`, and `launcher.log`. After the command returns,
artifact collection copies the selected instance's `logcat` once, if available,
with a 64 MiB cap, then renames it to `host-logcat.txt`. Oversized logcat is
truncated from a complete line boundary. Before retention, it receives the
capture's path, serial, MAC, secret, and attestation identifier-array
redactions. Arrays for `serial`, `imei`, `imei2`, and `meid` are replaced as a
whole. A missing or unsafe logcat is recorded in `MISSING.txt` and leaves the
capture incomplete. Runtime log snapshots remain available if Cuttlefish
removes those files during failed startup.
The runtime paths are discovered below
`$HOME/cuttlefish_runtime`, and stale files from previous runs are excluded.
`collect_composite_specs.py` reads `*_composite_disk_config.txt` files from
the selected instance runtime and writes `composite-disk-specs.json` as a
`files` object keyed by each source file's relative path. It preserves the
UTF-8 file contents and rejects matching config paths that are symlinks or
non-regular files (including FIFOs), as well as empty or invalid files, more
than 32 files, files above 256 KiB, aggregate content above 1 MiB,
inventories above 100,000 entries or 4096 directories, and directory depth
above 128. Unrelated symlinks are skipped without being followed. The
collector walks and opens descendants relative to directory descriptors with
no-follow flags, anchored to the per-run private Cuttlefish HOME. The capture
resolves `/tmp` to its physical path, requires that path to be covered by the
normalizer, and uses it for both HOME and `TMPDIR`. Caller-specific temporary
roots therefore cannot leak into Cuttlefish logs or configuration. Resolving
the path once also keeps Cuttlefish startup and removal on the same HOME when
`/tmp` is a symlink. This keeps temporary socket paths short. Host paths in
the JSON are normalized before the capture is retained. Interrupted
collection removes its temporary JSON before normalization. If that cleanup
fails, capture attempts to discard the staging tree; if removal also fails,
it reports the path for manual cleanup.

`guest-capture.txt` is a tab-separated list of output filename and shell
command. Each command uses plain `sh` syntax and runs through `adb exec-out`;
the commands are intended to work in the serial shell used by #014, but that
path remains unverified until the T3 console check. `logcat` is
compressed on the host with deterministic gzip metadata. The comparator refuses
gzip artifacts whose compressed or decompressed size exceeds 64 MiB. Serial
numbers, attestation identifier arrays for `serial`, `imei`, `imei2`, and
`meid`, MAC addresses, IPv6 addresses with EUI-64-style interface identifiers,
common host paths, and complete quoted or unquoted secret-keyed values are
normalized by `compare_boot.py` and `normalize.yaml`. Private-key blocks are
redacted by a linear marker scan.
JSON host paths are replaced inside escaped JSON string tokens so normalization
keeps the file valid. Escaped quotes in plain-text paths are handled by
non-overlapping alternatives to keep matching linear. The capture is taken
from a fresh development guest and must not contain secrets or user app data.
An incomplete capture may include a separate sanitized summary of bounded
host-crash or guest boot-state diagnostics that are not represented by its
normalized files. The summary identifies the evidence source and its limits;
it excludes raw core dumps and private app data. A summary does not make an
incomplete capture comparable.

### 8.4 Diff against the VZ boot

`compare_boot.py <reference dir> <vz capture dir>` compares normalized guest
artifacts and writes `report.json` and `report.txt` in the VZ capture directory.
The comparison categories and their input files are:

| Category | Files |
|---|---|
| `cmdline` | `cmdline.txt` |
| `bootconfig` | `bootconfig.txt` |
| `props` | `properties.txt` |
| `block devices` | `block-by-name.txt`, `block-sysfs.txt`, `block-sizes.txt` |
| `mounts` | `mounts.txt`, `fstab.txt` |
| `modules` | `modules.txt`, `first-stage-init.txt` |
| `HALs` | `lshal.txt`, `services.txt`, `apex.txt`, `features.txt`, `audio-cards.txt` |
| `hvc users` | `hvc-devices.txt`, `hvc-users.txt` |
| `network` | `ip-addr.txt`, `ip-route.txt`, `ip-link.txt`, `connectivity.txt` |
| `SELinux` | `selinux-mode.txt`, `avc-denials.txt` |

The comparator applies the same normalization rules in memory, so it does not
modify either input. It writes each report with an atomic replacement; report
symlinks are replaced without following their targets, and a symlink report
directory is rejected. `Images/tools/reference/compare_boot.py normalize <dir>` writes
normalization into a capture before it is committed. An empty category on
either side is reported as an unexplained missing capture input. Expected
differences are exact `{category, key, reason, design}` matches in
`Images/reference/<buildId>/expected-differences.yaml`; unused entries produce
warnings. Unexplained differences exit 1. The YAML files use the JSON-compatible
subset of YAML so the image tools need no additional parser dependency.

Full `dmesg`, `logcat`, `kernel.log`, and `launcher.log` are kept for diagnosis;
only the focused files in the table are compared automatically. The raw logs
include volatile startup details and are reviewed when recording boot markers
and phase timings.

Every difference must be listed in `Images/reference/<buildId>/expected-differences.yaml` with a reason (for example "slot_suffix: no U-Boot, fixed `_a`"). An unexplained difference fails the T3 check that belongs to gate G2. This is the verification in [ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md).


### 8.5 Gate G2 verification (#014)

The G2 gate ran from `691e114` on `task/014-system-server-boot` (rebased onto `main`), on arm64 Mac17,9, macOS 27.0.1 (26A434), build 16373615, with the default 600 s dwell (`dwell_seconds` 600 in the report from `30446a0` on; the earlier report carries `dwell: 600 (default)`). The run used `scripts/run-gate.sh`'s `xcodebuild` steps under `lockf -k /tmp/apkrun-vm.lock`.

| Check | Result |
|---|---|
| LinuxGuest suite | 49 run, 16 skipped, 0 failed |
| Five cold boots after an instance reset | each `sys.boot_completed` `1`; `ready` at 12.8 s (first boot), then 6.4, 7.4, 5.4, 5.4 s |
| `BOOT_COMPLETED` marker (`perf/boots.jsonl`) | 11.65 s (first boot), then 6.35, 7.41, 5.36, 5.35 s after `VM_START` |
| Stability, 10 minutes per boot | `sys.system_server.start_count` 1; no watchdog kill; no service outside the expected set that exited three or more times (the #095 crash-loop rule) |
| Reference diff after boot 5 (`compare_boot.py capture-vz`) | 30 differences, all explained (cmdline 5, bootconfig 25), exit 0 |
| Run time | 3063 s for the G2 target |

The run exposed two gate-path defects, both fixed on the branch: `expected-differences.yaml` is read beside the reference directory, so the test passes it explicitly; and the initial `.stopped` state of the VM controller counted as a guest stop during boot.

The gate closes from a clean `main` (IR-376). The network stages of the Android image are #095's checks and are not part of this table (IR-374).
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

`GPUProfileID.headless` is for bring-up only (#012–#017, `apkrun dev boot --gpu none`). "Headless" means nothing on the Mac shows Android; the guest still needs a DRM device. Its layer-2 keys are the launcher's `guest_swiftshader` graphics set (ANGLE on SwiftShader in the guest), and it adds `VMDefinition.builtInDisplay`, VZ's 2D virtio-gpu with one scanout ([vm.md](vm.md) §4). Cuttlefish's no-GPU set does not boot the stock image on VZ: without `ro.hardware.egl` zygote and SurfaceFlinger abort ("couldn't find an OpenGL ES implementation"), and `init.cutf_cvm.rc` waits for `/dev/dri/card0` (IR-307). Only development bundles list it in `gpuProfiles`, and `bundle` refuses to write it into a release-signed bundle ([graphics.md](graphics.md) §9; [../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.7, §7.3).

### 9.2 Field mapping

| `VMDefinition` field | Source |
|---|---|
| `label` | `"APKRun Android (" + imageVersion + ")"` |
| `cpuCount`, `memorySize` | `instance.json` sizing, which RuntimeCore refreshes from the settings `runtime.cpuCount` and `runtime.memoryGiB` before each boot ([vm.md](vm.md) §10) |
| `machineIdentifier` | `instance.json` |
| `boot` | `.linux(kernel:initialRamdisk:commandLine:)`. `kernel` is `Images/<v>/` + manifest `boot.kernel.path`. `initialRamdisk` is `Runtime/instance/boot/initrd.img`, built from `boot.ramdisk` and the merged bootconfig (§6.3). `commandLine` is the contents of the `boot.cmdline` file |
| `disks` | manifest `disks`, then `templates`, each in array order (§4.2). The `os` disk is `Images/<v>/` + its `path`, read-only, with caching `.automatic`. Each template is its instance clone `Runtime/instance/<file name of path>`, read-write, with synchronization `.full`. `readOnly`, `identifier`, and `role` come from the manifest entry ([../03-reference/runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.5) |
| `network` | three `.nat(macAddress:)` entries in the order of §7.4: the mobile and ethernet MACs from `instance.json`, and the `virt_wifi` MAC derived from `androidboot.wifi_mac_prefix` |
| `vsockEnabled` | `true` |
| `consolePorts` | manifest `consolePorts` (§7.1), roles adjusted by `BootOptions` (logcat capture, developer mode), then ordered by `ConsolePortPlan` ([vm.md](vm.md) §6.2). VirtualMachineCore puts ports 10–19 on one multiport device ([vm.md](vm.md) §6.1) |
| `builtInDisplay` | set only for `GPUProfileID.headless` (§9.1) |
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
| `templates` | `userdata.img`: the same fields, and `userdataStrategy` (`blankFormattable` / `prebuiltTemplate`, §5.2) |
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
- **Signing (#065):** `bundle` needs `--sign-key` and writes `SHA256SUMS` and `manifest.sig` with the tree. The unsigned path of #012 (`--unsigned`, `DevelopmentImage`, and `apkrun dev boot --bundle`) is removed. `apkrun dev boot` boots `current` ([cli.md](cli.md) §5).

### 10.3 Development install

`apkrun dev image install Images/work/16373615/bundle/` asks apkrund (or the embedded runtime before #031) to install the directory. ImageCore verifies it, `clonefile`s the files into `Images/.installing-<version>/`, renames the directory to `Images/<version>/`, and sets `current`. If there is no instance yet, it provisions one (§5.1). The installed tree is read-only: the write bits are removed after the full check of the copy, as runtime-image-manifest.md §3.1 requires (IR-359). Acceptance of #065: a bundle built from the stock image boots to `sys.boot_completed=1` under VZ.

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

`InstanceStore.createRecoveryPoint` writes `Runtime/instance/recovery-points/<timestamp>-<imageVersion>/` with `clonefile` copies of `userdata.img` and `instance.json`. The VM must be stopped. Clones are instant and share blocks, so the cost is the blocks changed afterwards. After a successful migration, only the most recent recovery point is kept.

### 12.3 Migration A → B

ImageCore provides the data steps. RuntimeCore's `RuntimeSupervisor` orchestrates the boot and health check, because ImageCore never starts VMs.

```text
preconditions  B installed and fully verified; A → B allowed (compatibility, userdata schema);
               no active sessions, or the user agreed; free space ≥ 10 GiB
1. stop VM gracefully (vm.md §9.3)
2. ImageCore: recovery point R of the instance (image A)
3. ImageCore: instance.json `migration` ← (A, B), which is `RuntimeImageState.migrating(A, B)`; then `previous` → A, `current` → B;
   instance.json imageVersion ← B
4. RuntimeCore: boot B with the existing `userdata.img` (first-boot timeout 15 min: package scan and dexopt)
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
| CF-04 | Raw GPT disk images instead of crosvm composite disks: two disks (`os.img` read-only, `userdata.img` read-write with `misc`, `metadata`, `frp`, `userdata`), and no sdcard disk | VZ attaches files; a third disk is `vdc`, which the stock fstab gives vold as `sdcard1` | §4.2 |
| CF-05 | `boot_devices` is `40000000.pci` (not `10000.pci`) | platform difference | §5.3 |
| CF-06 | Blank userdata formatted at first boot | clean instances; no host-side f2fs tools on macOS | §5.2 |
| CF-07 | In-guest non-secure KeyMint and Gatekeeper | no `secure_env` host process | §7.2 |
| CF-08 | Most hvc ports are silent sinks; hvc10–hvc19 are ports of one multiport device | no host services; VZ allows 10 single-port console devices | §7.1 |
| CF-09 | No vhost-user input devices; input through the Guest Agent | not reproducible on VZ | §7.6 |
| CF-10 | virtio-gpu is APKRun's custom virtio device (VirGL) instead of crosvm's; the M1 `headless` profile uses VZ's 2D virtio-gpu with the `guest_swiftshader` keys | VZ custom virtio API; the stock image needs a DRM device to boot | [graphics.md](graphics.md) §9, §9.1 |
| CF-11 | Network: three VZ NAT NICs in Cuttlefish's order, Wi-Fi through `virt_wifi` on `eth2` instead of `mac80211_hwsim_virtio` and the OpenWRT VM | VZ has no virtio Wi-Fi device; vmnet filters source MACs | §7.4 |
| CF-12 | No modem simulator, rootcanal, GNSS, camera hosts; the sensors host is a "no sensors" responder on hvc18 | out of v1 scope; the sensors HAL blocks `system_server` without a reply | §7.1, §7.6 |
| CF-13 | Launcher keys for host-side clients are dropped (`vsock_tombstone_port`, `vhal_proxy_server_port`, `auto_eth_guest_addr`); keys for guest-side servers and the RIL stay | no host services; their HALs abort without the guest-side keys | §6.2, §7.3 |
| CF-14 | `androidboot.cuttlefish_service_bluetooth_checker=false`, and first-boot settings: Bluetooth off, Wi-Fi on and joined to `VirtWifi` | no rootcanal; Wi-Fi defaults off | §7.6 |
| CF-15 | `androidboot.console=hvc1` and `serialconsole=1` in developer mode | the Android serial shell is the debug channel before ADB | §6.2 |
| CF-16 | AVB reports `OK_NOT_SIGNED`, an unknown key, and `VerificationError` for `/system` and `/system_dlkm`; the boot continues with `verifiedbootstate=orange` | the development vbmeta is unsigned; release images are signed (§11.4) | §6.6 |
| CF-17 | The kernel logs `KVM is not available. Ignoring kvm-arm.mode`: the built-in `kvm-arm.mode=protected` has no effect | VZ does not expose pKVM; the Cuttlefish reference host runs pKVM | §6.6 |
| CF-18 | `log_buf_len=2M` is added to the command line | the default 256 KiB buffer wraps before the serial shell answers, so `dmesg` loses the boot's first lines | §6.4, §6.6 |
| CF-19 | The reference command line has `earlycon=uart8250,mmio,0x3f8`, `ramoops.mem_address`, `ramoops.mem_size`, and a second `panic=-1`; none is passed on VZ | crosvm's UART and ramoops buffer do not exist on VZ; the second `panic` repeats the first | §6.4, §6.6 |

New rows are added whenever #011–#014, #035, #083, or #095 find a difference. #035 adds the product changes of §11.2 that differ from Cuttlefish at runtime (for example the developer-mode gate of adbd, §11.3).

---

## 14. Errors, logging, health

### 14.1 `ImageFailure` (error domain `image`)

| Case | When | Remediation shown |
|---|---|---|
| `manifestInvalid(path, reason)` | schema or semantic check failed | reinstall the image |
| `signatureInvalid(keyID)` / `untrustedKey(keyID)` | bad or unknown signature | reinstall from the official feed; in development, trust your dev key |
| `unexpectedFile(file)` | a bundle holds a file its manifest does not list, or an installed image of the same version has a different manifest | reinstall the image; run `apkrun doctor --deep` |
| `imageNotInstalled(version)` | an activation names a version with no directory under `Images/` (#065) | install that image first, or choose an installed one |
| `noCurrentImage` | a boot or a verification needs `Images/current`, and it does not exist (#065) | install an Android system; developers run `apkrun dev image install <bundle>` |
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
| T2 | Linux test guest sees the two disks with the right partition names and sizes; `/proc/bootconfig` equals the golden trailer; `boot_devices` value discovered | #011, #012 |
| T2 | Stock image: kernel boot (#012), init (#013), `sys.boot_completed=1` and stable for 10 minutes (#014), ADB commands (#015) | #012–#015 |
| T2 | Console port numbering with 20 ports; each hvc role behaves as planned | #095 |
| T2 | Migration A → B, and a failed migration B → B′ that returns to B (§12.4) | #058 |
| T3 | Gate G2: boot_completed, and the reference diff over the categories the launcher captures provide (cmdline, bootconfig) with no unexplained differences | #014 |

---

## 16. Open items

Risks (R-NN) are in [../04-plan/risks.md](../04-plan/risks.md), open questions (OQ-NN) in [../04-plan/open-questions.md](../04-plan/open-questions.md).

| Item | Plan |
|---|---|
| Sizes of the blank partitions in the manifest (§3.2) | #011 reads the real sizes from the composite disk specs in the launcher captures (§8.1) |
| Ramdisk fragment policy: every non-recovery fragment, in table order (§4.1) | #013 compares the first-stage module list (`lsmod` and the first-stage init log) with the reference capture |
| Partitions left out on VZ: `uboot_env`, `bootconfig`, the persistent vbmeta, `android_esp`, `pvmfw_a`, `vvmtruststore`, `hibernation` (§4.2) | #011 checks each one against the reference `ls -l /dev/block/by-name` and the fstab. A partition that turns out to be required is added blank, and each correction is recorded in §13 |
| Whether a component needs `_b` partitions (§4.2) | #013, #014. If one does, equal-sized zero-filled `_b` partitions are added (holes on APFS) |
| The VZ virtio-blk logical sector size is 512 bytes (§4.4) | #005 and #011 check it with `blockdev --getss` |
| Android formats the blank userdata on first boot: `formattable` on `/data` and `/metadata`, and the metadata encryption path (§5.2) | #011 reads `/vendor/etc/fstab.*` in the reference capture, #013 boots it. If first-boot formatting fails under VZ: fallback A (the zip's `userdata.img`) or fallback B (a `make_f2fs` template), both with a fixed size |
| Whether the `androidboot.boot_devices` value `40000000.pci` is stable across macOS builds (§5.3, R-16) | #011 records `topology.txt`, and the T2 suite re-checks it on every new macOS build. Alternative: `androidboot.boot_part_uuid` with a single-disk layout, not built unless needed |
| `drm_virgl` graphics keys for the target profile (§6.2) | the launcher captures hold the `guest_swiftshader` set; #022 takes the `drm_virgl` set from `graphics-props-from-source.txt` and the Cuttlefish source |
| The stock image on the VZ topology (R-06) | spike positive (IR-306); #012–#014 build it into the product and close G2. Fallback: adapt the custom image (#035): kernel config, fstab, init scripts |
| Direct kernel boot misses something that U-Boot provides (R-11, §6) | spike positive: nothing was missing (IR-306). Fallback: a U-Boot EFI build ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)) |
| Cuttlefish host services: 20 console ports, HALs on silent ports, Weaver, vsock clients without their keys (§7.1, §7.3, R-12) | the spike found the handling of §7 (IR-306); #095 verifies the 20-port numbering with markers and builds the substitutes, #014 the stability check. Weaver is `none`; LockSettings is checked in #095 |
| Network (§7.4, OQ-37) | the spike found option 2 with `virt_wifi` (IR-306); #095 builds and verifies it |
| `virtio_snd` in the stock kernel (§7.5, OQ-38) | #083. If it is missing, the custom image adds it |
| RIL, Bluetooth, GNSS, and sensors without host services (§7.6) | handled as in §7.6. The custom image disables a HAL only if #095 measures crash loops or CPU and log cost |
| The PL031 RTC driver (§7.6) | #012 checks `/dev/rtc0` |
| Boot phase marker strings and their timing (§7.7) | observed on the VZ boot (§17); #014 records them in `BootSignals` |
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
| VZ virtio-blk logical sector size | #005, #011 | 2026-10-09, macOS 27.0.1 (26A434): `logical_block_size` 512 on both Android disks (§4.4) |
| Kernel compression, ramdisk fragment list, and command-line length of the pinned build | #010 | 2026-10-01; rechecked 2026-10-06 on macOS 27.0 (26A428); build 16373615: uncompressed 42,031,616-byte kernel; one unnamed `PLATFORM` fragment of 18,816,072 bytes, included; current command line 157 bytes. Reference-derived command-line additions remain pending #064. |
| VZ direct-boot spike of the stock image (IR-306) | spike | 2026-10-08 UTC, arm64 Mac17,9 (M5 Pro), macOS 27.0.1 (26A434), build 16373615, harness `Experiments/vz-android-boot/`: kernel, first-stage init, dynamic partitions, AVB (`orange`/`unlocked`, `avb.py` digest), and first-boot formatting of `/metadata` and `/data` all worked. `/proc/bootconfig` equalled the merged block (49 keys, 2574 bytes). `getenforce` was `Enforcing` with no AVC denials. `/dev/rtc0` existed with the correct date. `VIRTUAL_DEVICE_BOOT_COMPLETED` came at 7.5 s on a first boot. `g2_spike.py` passed five cold boots in a row, each stable for 10 minutes with `sys.system_server.start_count` 1, no Watchdog kill, no init service exiting three times, and no tombstone (three-disk layout); the two-disk layout passed two cold boots. The handling it needed is in §4.2, §7, and §9.1 |
| Real sizes of the blank partitions; omitted partitions not needed | #011 | the manifest sizes (`misc` 1 MiB, `metadata` 64 MiB, `frp` 1 MiB) booted in the spike; `_b` slots, `uboot_env`, `bootconfig`, and the persistent vbmeta were not needed. #011 confirms them against the composite specs (§3.2, §4.2) |
| fstab `formattable` flags and the metadata encryption path | #011 | confirmed in the spike: `formattable` on `/data` and `/metadata`, `keydirectory=/metadata/vold/metadata_encryption` (§5.2) |
| Signed stock bundle, install, and boot (#065) | #065 | 2026-10-09, macOS 27.0.1 (26A434), build 16373615. `scripts/build-test-android-bundle.sh` built the signed bundle twice from the same inputs, and `manifest.json`, `manifest.sig`, and `SHA256SUMS` were byte-identical. `os.img` allocates 1.8 GB for 8.7 GB logical after the zero-block fix (§4.3). `apkrun dev image install` made the image current, and `apkrun dev boot` reached `ready` in 13.7 s. `G2AndroidBootTests` passed five cold boots from the installed bundle, each with `sys.boot_completed=1`, with a 60-second dwell instead of 600 seconds. |
| Guest-visible topology and `androidboot.boot_devices` value | #011 | 2026-10-09, macOS 27.0.1 (26A434): `40000000.pci`; the disks, PCI functions, and device-tree nodes are in `Images/reference/vz/26A434/topology.txt` (§5.3) |
| Direct kernel boot of the stock image; `/dev/rtc0` present | #012 | positive in the spike. 2026-10-09, macOS 27.0.1 (26A434), build 16373615: `apkrun dev boot` boots through `AndroidBootPlanner` and `RuntimeSupervisor`, and the console shows `[vda]` with nine partitions and `[vdb]` with four. `AndroidBootTests.testKernelBoot` passes in 1.1 s. `AndroidBootTests.testKernelPanicDetected` passes with `bootStalled(kernel)` (IR-361). `/dev/rtc0`, `/proc/cmdline`, and `/proc/bootconfig` are checked over the serial shell in #013 (§6.5) |
| Init checks on the product path (#013): debug ramdisk, fstab, dynamic partitions, boot device names, AVB, bootconfig, SELinux, `/proc/cmdline`, devices | #013 | positive. 2026-10-09, macOS 27.0.1 (26A434), build 16373615: `AndroidBootTests.testReachesInit` passed in 15.3 s, with the results of §6.6 and the `log_buf_len=2M` addition |
| First-stage modules; `/dev/block/by-name/` has every label; first-boot userdata formatting | #013 | positive in the spike: 19 first-stage modules loaded, every §4.2 label present, `/data` formatted on the first boot (§4.1, §5.2, §5.3) |
| `sys.boot_completed=1` with the `headless` profile; `_b` partitions not needed | #014 | positive. 2026-10-09, arm64 Mac17,9, macOS 27.0.1 (26A434), build 16373615: the gate ran from `691e114` on `task/014-system-server-boot` (rebased onto `main`) and passed five cold boots with a 600 s dwell each, the reference diff having 30 explained and no unexplained difference (§8.5). The gate is repeated from a clean `main` after the merge |
| AVB state of the release variant; SELinux denials on the custom image | #035 | pending (§11.4, OQ-36, R-13) |
| Reference capture: U-Boot inputs, boot phase markers, diff against the VZ boot | #064 | re-scoped (IR-305): no complete crosvm boot on the nested reference host; the launcher captures are kept, and the boot markers were observed on VZ (§7.7, §8.1) |
| `virtio_snd` in the stock kernel | #083 | pending (OQ-38) |
| Archive extraction time and bytes written | #087 | pending (R-25) |
| 20 console ports, silent-port HAL behaviour, Weaver, vsock clients, RIL cost | #095 | spike: VZ allows 10 single-port devices, ports 10–19 on one multiport device; hvc holders and client behaviour as in §7.1, §7.3, and §7.6; Weaver is `none`. The 2026-10-09 G2 run with the production code had no HAL crash loop over five 10-minute dwells. Marker verification and the RIL's CPU and log cost are pending |
| Network on the stock image | #095 | spike: three NICs and `virt_wifi` gave a validated Wi-Fi network (§7.4); the production path is pending (OQ-37) |
| Port markers on the test kernel, host-service substitutes, and the network (#095) | #095 | 2026-10-09: eight-port marker identity passes; `testHostServiceSubstitutes` passes; the network fails on the Wi-Fi join, and the 20-port marker test is blocked by the test kernel's eight hvc nodes (§7.8, IR-372, IR-374) |
