# Android Image Design (Images/tools + ImageCore)

This document specifies how APKRun builds, checks, stores, and boots the Android image: the Cuttlefish artifacts and manifests, the disk layout, bootconfig and the kernel command line, the substitutes for Cuttlefish host services, the reference capture, the runtime image bundle, the APKRun AOSP product, and migration between image versions.

## 1. Responsibilities and split

| Half | Where | Language | Runs on | Owns |
|---|---|---|---|---|
| Build-time tooling | `Images/tools/` | Python 3.12 | developer Mac, Linux builder, CI | Fetch, inventory, `AndroidImageManifest`, extraction, sparse to raw, GPT assembly, bootconfig baseline, bundles and signing, reference capture and diff |
| Runtime | `Packages/ImageCore` | Swift | `apkrund` | Installing and verifying bundles, the image store (`current`, `previous`), the instance, per-boot initrd, bootconfig merge, the Android parts of `VMDefinition`, recovery points, migration data steps |

Rules:

- No code opens an Android image file by a hard-coded name. Names come from the inventory, then the `AndroidImageManifest`, then the runtime image manifest.
- ImageCore never parses AOSP build outputs. It consumes only finished bundles ([ADR-0011](../01-architecture/decisions/0011-runtime-image-bundle.md)).
- ImageCore never starts a VM. RuntimeCore orchestrates boots and health checks (§12.3).
- Downloaded originals are never modified. Derived files go to `Images/work/<buildId>/` or into the bundle.

Non-goals for v1: in-guest OTA, A/B slots, recovery mode, U-Boot ([ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md)), and more than one Android instance.

### 1.1 Pipeline overview

```text
ci.android.com build ──fetch (§2.2)──▶ Images/work/<buildId>/download/
  ──inventory (§3.1)──▶ Images/manifests/<buildId>/inventory.json
  ──AndroidImageManifest (§3.2)──▶ Images/manifests/<buildId>/android-image.json
  ──extract (§4.1), disks (§4.5), bootconfig baseline (§6)──▶ runtime image bundle (§10)
  ──apkrun dev image install | feed archive (§10.4)──▶ Images/<imageVersion>/
  ──per boot: initrd, cmdline, disk list, console plan──▶ VMDefinition ──▶ VirtualMachineCore
```

### 1.2 Tooling layout

```text
Images/
├── tools/
│   ├── apkrun_image/     # python3 -m apkrun_image <command>; one module per concern (§2–§4, §6, §10)
│   ├── layouts/cuttlefish-phone-arm64.json   # disk plan, console ports, bootconfig baseline, GPU profiles
│   ├── schemas/          # JSON Schemas of the Android and runtime image manifests
│   ├── reference/        # reference capture and comparison (§8)
│   ├── vendor/           # pinned mkbootimg.py, unpack_bootimg.py, avbtool.py
│   └── tests/            # pytest tests and synthetic fixtures
├── manifests/<buildId>/  # committed: inventory.json, android-image.json
├── reference/<buildId>/<profile>/  # committed reference captures (§8)
├── reference/vz/<macOS build>/     # committed VZ topology captures ([vm.md](vm.md) §5)
└── work/<buildId>/       # git-ignored: downloads and derived artifacts
scripts/inventory-cuttlefish.py     # inventory entry point
```

The vendored `mkbootimg` and `avbtool` revisions are pinned in `ThirdParty/ThirdParty.lock.json` ([build-system.md](../05-development/build-system.md) §6).

---

## 2. Acquisition

### 2.1 Selected source

| Item | Value |
|---|---|
| Site, branch, target | ci.android.com, `aosp-android-latest-release`, `aosp_cf_arm64_only_phone-userdebug` |
| Pinned build | `16373615` (2026-09-17); artifact `aosp_cf_arm64_only_phone-img-16373615.zip` |
| Reference host only | `cvd-host_package.tar.gz` (§8). Its binaries are aarch64 Linux ELF and do not run on macOS. |
| Android version | Android 17 (API 37), from the boot image `os_version` and `ro.build.version.sdk` |

The pin is the `source` block of `Images/manifests/<buildId>/android-image.json`. A new build is a normal change: fetch, inventory, rebuild the bundle, then run the T2 boot suite and the reference diff (§8.4).

### 2.2 Fetch tool

```bash
python3 -m apkrun_image fetch --branch aosp-android-latest-release \
  --target aosp_cf_arm64_only_phone-userdebug --build 16373615 \
  --artifact 'aosp_cf_arm64_only_phone-img-*.zip' --out Images/work/16373615/download/
```

- It uses the Android Build API v4. The API key comes from `APKRUN_ANDROID_BUILD_API_KEY` and is not committed ([environment-setup.md](../05-development/environment-setup.md)). A manual download from the web UI is the fallback; `fetch` then only verifies.
- Downloads resume with `Range`. A finished download is checked against its declared size and SHA-256, made read-only, and hard-linked atomically to its final name. An existing artifact is never overwritten.
- `download/fetch.json` records each name, size, and SHA-256, and `branchProvenance: "caller-asserted"`.
- Artifacts are capped at 16 GiB. HTTPS is required for API and artifact URLs. The Python test API may opt into loopback HTTP; HTTPS never redirects to HTTP.
- A second run downloads nothing and re-verifies the hashes.

### 2.3 Licensing note

The prebuilt image is for development only (M1–M4). Release images are built from source (§11). See [legal-and-licensing.md](../05-development/legal-and-licensing.md) and R-10.

---

## 3. Inventory and AndroidImageManifest

### 3.1 Inventory

`scripts/inventory-cuttlefish.py <zip or directory> [--out inventory.json]` classifies every entry **by content**. File names are hints only. The detection rules and recorded details are in [android-image-manifest.md](../03-reference/android-image-manifest.md) §4.4; input bounds are in §4.5.

- Each input is copied into a private, size-bounded snapshot while it is hashed, and classification reads that snapshot. Directory files and ZIP archives are re-hashed after parsing, and a persistent change is rejected.
- Snapshots use at most 8 MiB of memory, then spill to a per-user mode-0700 temporary directory. Free space must cover the input plus a 256 MiB reserve.
- With one archive and `fetch.json` in the directory, the archive is checked against the sidecar. `fetch.json` is unsigned, so this does not authenticate it.
- Unknown files are listed as `kind: unknown`, never dropped. `probablePurpose` derives from content, never from the name. A mismatch sets `nameMismatch: true`.
- Output is deterministic: a second run is byte-identical.

### 3.2 AndroidImageManifest

The inventory says what is there. The `AndroidImageManifest` says what each artifact is for. The `manifest` command generates it, a person reviews it, and it is committed per build. Schema and fields: [android-image-manifest.md](../03-reference/android-image-manifest.md) §6–§7; complete example: §5.

- `roles.kernel` is `boot`. `roles.genericRamdisk` is `init_boot` (Android 13+). `roles.vendorBoot` is `vendor_boot`. `roles.vbmeta` lists the top-level and chained vbmetas. `roles.super` is `super`. `roles.userdataTemplate` is `userdata`, used only by fallback A (§5.2).
- `system`, `system_ext`, `product`, `vendor`, `vendor_dlkm`, `odm`, `odm_dlkm`, and `system_dlkm` are logical partitions inside `super`.
- The zip has no `metadata` image. The blank partitions are `misc` (1 MiB), `metadata` (64 MiB), and `frp` (1 MiB).
- `android.sdk` comes from a table keyed by the `os_version` release (17 → 37), cross-checked against `ro.build.version.sdk`.

### 3.3 Validation

The same JSON Schema (`Images/tools/schemas/android-image-manifest.schema.json`) is enforced by Python and by ImageCore's Swift `Codable` model, which reads provenance only. Checks run in order: M1 (`schemaVersion`), the schema, then M2–M13 ([android-image-manifest.md](../03-reference/android-image-manifest.md) §8). A newer `schemaVersion` is refused. A version change rewrites every committed manifest in the same change.

| # | Check | Error message pattern |
|---|---|---|
| M1 | `schemaVersion` known | `android-image.json: schemaVersion 3 is newer than this tool supports (1). Update Images/tools.` |
| M2 | Every role points to an existing artifact `id` | `roles.vendorBoot = "vendor_boot2": no artifact with that id. Known ids: boot, init_boot, …` |
| M3 | Artifact kind matches role | `artifacts[2] (role vendorBoot): expected kind vendorBootImage v4, found bootImage v4. Is the file swapped?` |
| M4 | File exists; size and SHA-256 match | `super.img: SHA-256 mismatch (expected …, got …). Re-run fetch or re-inventory.` |
| M5 | `architecture == arm64` | `architecture x86_64 is not supported. Use an arm64 target.` |
| M6 | Boot header versions (boot, init_boot, vendor_boot v4) | `vendor_boot.img header v3 is not supported (needs v4 ramdisk table).` |
| M7 | No duplicate partition names | `partition "misc" appears in artifacts[7] and blankPartitions[0].` |

Invalid fixtures are in `Images/tools/tests/fixtures/manifests/invalid/` with their expected messages. The Swift test runs the same fixtures and skips the checks listed in `invalid/python-only.txt`.

---

## 4. Boot artifacts and GPT disk layout

### 4.1 Boot artifact extraction

`python3 -m apkrun_image extract --manifest Images/manifests/<buildId>/android-image.json --out Images/work/<buildId>/boot/`

| Output | Content |
|---|---|
| `kernel` | Decompressed if needed (gzip `1f 8b`, LZ4 legacy `02 21 4c 18`, LZ4 frame `04 22 4d 18`). Must carry the arm64 Image magic `ARM\x64` at offset 0x38. |
| `ramdisk.img` | `vendor_boot` v4 fragments in table order, without type `RECOVERY`, then the `init_boot` generic ramdisk, concatenated byte for byte. |
| `vendor-bootconfig.txt` | The `vendor_boot` bootconfig section: layer 1 (§6.1). |
| `cmdline.txt` | Vendor cmdline, boot cmdline, and the APKRun additions (§6.4). |
| `dtb`, `extraction.json` | The DTB is recorded, not used (VZ has its own). `extraction.json` holds hashes, sizes, header fields, and the ramdisk table. |

- `bootimg.py` accepts only boot, init_boot, and vendor_boot v4. It bounds every header, payload, table, and fragment before reading. Vendor page sizes are 2048 to 16384 bytes. Fragments cover the vendor ramdisk exactly. Tables are capped at 16 MiB and 4096 entries.
- `kernel.py` streams decompression with a 1 GiB output limit. Concatenated gzip, LZ4 frame, and legacy LZ4 members decode as one kernel.
- Inputs are re-hashed after extraction to prove they did not change.
- Build 16373615: the kernel is uncompressed (boot section 42,031,616 bytes, `text_offset` 0, `image_size` 42,795,008, `flags` 10). The vendor table has one unnamed PLATFORM fragment and no RECOVERY fragment.
- The fragment policy (all non-recovery fragments in table order) matches a default AOSP bootloader. §6.6 checks the first-stage modules.

### 4.2 Disk plan

Cuttlefish under crosvm gives the guest composite disks whose GPT names first-stage init and fstab rely on (`/dev/block/by-name/<name>`). APKRun builds raw GPT images with the same names. The mapping is data in the `disks` section of `Images/tools/layouts/cuttlefish-phone-arm64.json`, copied into the runtime manifest. No Swift code lists partitions.

1. **Names mirror `os_composite`.** A/B partitions exist only as `_a`, because bootconfig fixes slot `_a`.
2. **Read-only system disk.** Everything Android never writes goes into `os.img`, attached read-only.
3. **One writable disk.** `userdata.img` holds `misc`, `metadata`, `frp`, and `userdata`, `userdata` last so it can grow (§5.2). A third disk is not used: the stock fstab gives `vdc` to vold as `sdcard1`.
4. **Partition size equals image size.** AVB footers sit in the last 64 bytes of a partition. `super` is sized to its unsparsed logical size.
5. **Omit what VZ does not need:** `uboot_env`, `bootconfig`, persistent vbmeta, `android_esp`, `pvmfw_a`, `vvmtruststore`, `hibernation`. A partition found to be required is added blank and listed as a deviation in §13.

| VZ disk | File | Access | Identifier | GPT partitions (label ← source) |
|---|---|---|---|---|
| 0 | `Images/<v>/disks/os.img` | read-only | `apkrun-os` | `boot_a` ← boot.img · `init_boot_a` · `vendor_boot_a` · `vbmeta_a` · `vbmeta_system_a` · `vbmeta_system_dlkm_a` · `vbmeta_vendor_dlkm_a` · `super` ← super.img (unsparsed) · `custom` |
| 1 | `Runtime/instance/userdata.img` | read-write | `apkrun-data` | `misc` · `metadata` · `frp` (blank) · `userdata` (blank or template, §5.2), last |

Guests see `/dev/block/by-name/<label>`. `boot_a`, `init_boot_a`, and `vendor_boot_a` are not read by direct boot, but vbmeta describes them. If a component needs `_b` partitions, equal-sized zero-filled `_b` partitions are added.

### 4.3 Sparse to raw

`sparse.py` reads the Android sparse format: a 28-byte header (magic `0xED26FF3A`) and chunks RAW `0xCAC1`, FILL `0xCAC2`, DONT_CARE `0xCAC3`, CRC32 `0xCAC4`. Output goes straight into the partition's range of `os.img`. DONT_CARE and zero FILL chunks, and all-zero 4 KiB blocks, become holes (`write_skipping_zeros`). CRC32 chunks are verified when present, and the block total must equal `total_blks`. T1: output hashes equal `simg2img` 1.1.5 output for the fixtures and the real `super.img`.

### 4.4 GPT writer

`gpt.py` writes and reads GPT with 512-byte logical sectors (the VZ virtio-blk size).

- A protective MBR, the primary header at LBA 1, 128 entries of 128 bytes at LBA 2–33, and the backup at the end. CRC32 covers the header and entry array. Partitions start on 1 MiB boundaries.
- Type GUID: Linux filesystem data (`0FC63DAF-8483-4772-8E79-3D69D8477DE4`). Names are UTF-16LE, at most 36 code units, case-sensitive.
- GUIDs of `os.img` and the templates are UUIDv5 over (`imageVersion`, disk role, label). Per-instance disks get new GUIDs at provisioning (§5.1).
- ImageCore's `GPTDisk` relocates headers and provisions disks, but creates no partitions. Its GUIDs are UUIDv5 over `instance/<instance UUID>/<role>[/<label>]`. Fixture: `Images/tools/tests/fixtures/gpt/provision.json`.

### 4.5 Assembly and verification

`python3 -m apkrun_image disks --manifest … --layout layouts/cuttlefish-phone-arm64.json [--image-version <v>] --out Images/work/<buildId>/disks/` writes `os.img`, `userdata.img`, and `disks.json` (per disk: role, access, identifier, sizes, disk GUID, `userdataStrategy`; per partition: label, GUID, LBAs, size, source, content SHA-256). Each artifact must equal its manifest SHA-256 when copied. `inspect <disk>` prints the partition table.

Checks: in the Linux test guest, `/init` prints each partition's `PARTNAME` and size, matching `disks.json` ([vm.md](vm.md) §12). On the Android kernel, `virtio_blk` reports two disks with 9 and 4 partitions.

### 4.6 Super rewrite

Development bundles replace parts of the stock bundle.

- **`vendor-reseal`** (`apkrun_image.vendor_reseal`) reseals the injected `vendor_a` with a fresh hashtree footer that keeps the stock data and hash block size, algorithm, salt, and name, with no FEC. It updates the vendor descriptor in the stock `vbmeta_a` with `avbtool update_partition_descriptor`, keeping the rollback index and other descriptors.
- **`lp_write.replace_partition`** (`apkrun_image.lp_write`) replaces one linear partition in a sparse `super.img`. The partition keeps its size and extents, and metadata stays byte-identical. A shorter image is zero-padded; a larger one fails with `PartitionTooLargeError`. The output stays sparse (`sparse.rewrite_ranges`). It refuses a raw super, a whole-image or CRC32 checksum, trailing bytes, and non-linear or unaligned extents. The output is linked after all checks, and the link fails if the destination exists.
- **`bundle-variant`** (`apkrun_image.bundle_variant`) replaces one `super` partition and `vbmeta_a` in the stock bundle. `--image-version` is required in `YYYY.MM.N` form; build identity, `arm64`, `kind`, and provenance are kept. The stock vbmeta must verify against the AOSP test key `2597c218aae470a130f61162feaae70afd97f011` (`SHA256_RSA4096`), accepted only for `kind: stock`. Descriptors are compared as raw encodings. `androidboot.vbmeta.digest` and `.size` are recomputed. Every byte outside the replaced extents equals the stock bytes. `manifest.sig` uses the developer key. `variant.json` (schema version 3) sits beside the bundle, not inside it. The build does not boot the variant.

---

## 5. Instance disks

### 5.1 Provisioning

The instance is created on first run or by "Reset Android" (FR-OPS). Steps, all in `Runtime/instance/`:

1. Write `instance.json`: a new instance UUID, a `VZGenericMachineIdentifier`, a locally administered MAC, CPU and memory ([vm.md](vm.md) §10), `imageVersion`, `userdataSchemaVersion`, and a new `userdataGeneration` UUID ([package-store.md](package-store.md) §9.2).
2. `clonefile(2)` the template `Images/<v>/templates/userdata.img` to `userdata.img`. On a non-APFS volume, fail with `ImageFailure.cloneUnsupported`. APKRun never copies multi-GB files (NFR-RES).
3. Give the disk new disk and partition GUIDs derived from the instance UUID, and rewrite the GPT CRCs.
4. Grow `userdata.img` to the configured size (§5.2).
5. `fsync` the files and directory, then write `instance.json` last. Without it, provisioning starts over.

### 5.2 userdata: format, size, growth

Primary approach: **blank userdata, formatted by Android on first boot.** The template is a GPT with blank `misc`, `metadata`, and `frp` and a last `userdata` partition, all holes. At provisioning ImageCore extends the file sparsely, moves the backup GPT, and extends `userdata` to the new last usable LBA. The fstab marks `/data` and `/metadata` `formattable`.

Fallbacks, used only if first-boot formatting fails under VZ: **A**, the zip's `userdata.img` as template; **B**, a `make_f2fs` template stored sparse. Both have fixed size.

- `runtime.userdataGiB` ([configuration.md](../03-reference/configuration.md)): default 32 GiB, minimum 8 GiB, maximum 256 GiB and at most the free space at provisioning minus 10 GiB.
- v1 fixes the size at provisioning. Growing formatted userdata needs an offline `resize.f2fs`, which neither the guest nor the host can run. Changing the size is "Reset Android" after the user confirms data loss. Online growth is post-v1.

### 5.3 `androidboot.boot_devices`

First-stage init creates `/dev/block/by-name/*` only for block devices under a device named in `androidboot.boot_devices` (or `boot_device`). On VZ all virtio-blk devices sit behind one `pci-host-ecam-generic` bridge at `0x40000000` ([vm.md](vm.md) §5), so one value covers both disks: **`40000000.pci`**.

- Discovery: the Linux test guest prints `readlink -f /sys/block/vda`, and the platform component is the value. It is stored with the topology capture (`Images/reference/vz/<macOS build>/topology.txt`) and compiled as `VZPlatformProfile.bootDevices`.
- The T2 suite re-checks it on each new macOS build (R-16): `LinuxGuestAndroidDiskLayoutTests` asserts both disks sit under `40000000.pci`.
- Fallback if the path changes: `androidboot.boot_part_uuid`. It requires all partitions on one disk and is not built.

---

## 6. Bootconfig and command line

### 6.1 Layers and merge

Android 12+ reads `androidboot.*` keys from bootconfig, exposes them at `/proc/bootconfig`, and mirrors them as `ro.boot.*`. The kernel reads one block at the end of the initrd. ImageCore builds it before each boot from four layers:

| Layer | Stored in | Produced by | Examples |
|---|---|---|---|
| 1. Vendor | `boot/bootconfig.txt` `[vendor]` | `bundle` (§10.2) | `androidboot.hardware`, vsock buffer size |
| 2. Image | `boot/bootconfig.txt` `[image]`, `gpuProfiles` | `bundle`: layout, `avb.py`, capture | slot, AVB, fstab suffix, HALs, graphics |
| 3. Platform | `VZPlatformProfile` | host app | `androidboot.boot_devices` |
| 4. Instance | computed at boot | ImageCore | serial, density, memory size, APKRun flags |

- A key appears in one layer only; an identical duplicate is dropped with a debug log. A conflict is `ImageFailure.bootconfigConflict(key, layerA, layerB)`, unless the later layer lists the key in `overrides`.
- Keys match `[A-Za-z0-9_.-]+`. Values are printable ASCII without `"`, backslash, or newline, and are double-quoted.
- At most 1024 tree nodes. The serialized block is at most 32 KiB (kernel limit); the build fails above 16 KiB to leave room for layers 3 and 4.

### 6.2 Key catalogue

The layout file is the source of truth. Image-layer values come from the Cuttlefish 1.57.0 launcher capture of build 16373615 unless noted. Values that differ from the capture are listed in `expected-differences.yaml` (§8.4).

| Key | Value | Layer | Notes |
|---|---|---|---|
| `androidboot.hardware` | `cutf_cvm` | 1 | vendor_boot |
| `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size` | `16384` | 1 | vendor_boot |
| `androidboot.slot_suffix` | `_a` | 2 | ADR-0015 |
| `androidboot.force_normal_boot` | `1` | 2 | direct boot |
| `androidboot.verifiedbootstate`, `androidboot.vbmeta.device_state` | `orange`, `unlocked` | 2 | development; release in §11.4 |
| `androidboot.vbmeta.{digest,hash_alg,size,avb_version,invalidate_on_error}` | computed by `avb.py` (below) | 2 | build time |
| `androidboot.console`, `androidboot.serialconsole` | `hvc1`, `1`; developer mode only | 4 | CF-15 |
| `androidboot.hw_timeout_multiplier` | `3` | 2 | capture |
| `androidboot.hypervisor.vm.supported` | `0` | 2 | arm64 default; not in capture |
| `androidboot.vendor.apex.com.android.hardware.keymint`, `androidboot.vendor.apex.com.android.hardware.gatekeeper` | `com.android.hardware.keymint.rust_nonsecure`, `com.android.hardware.gatekeeper.nonsecure` | 2 | §7.2 |
| `androidboot.vendor.apex.com.android.hardware.weaver`, `androidboot.vendor.apex.com.android.hardware.strongbox` | `none` | 2 | capture |
| `androidboot.vendor.apex.com.android.hardware.graphics.composer` | `com.android.hardware.graphics.composer.ranchu` | 2 (GPU) | `headless` |
| `androidboot.vendor.apex.com.google.cf.vulkan` | per profile; none for `drm_virgl` | 2 (GPU) | no profile sets it |
| `androidboot.hardware.egl=mesa`, `androidboot.hardware.gralloc=minigbm`, `androidboot.hardware.hwcomposer=ranchu`, `androidboot.hardware.hwcomposer.mode=client`, `androidboot.hardware.hwcomposer.display_finder_mode=drm`, `androidboot.cpuvulkan.version=0`, `androidboot.opengles.version=196608` | `drm_virgl` set; others per [graphics.md](graphics.md) §9 | 2 (GPU) | `guest_swiftshader` and `headless` match the capture; `drm_virgl` is from source only (§16) |
| `androidboot.wifi_impl`, `androidboot.wifi_mac_prefix` | `virt_wifi`, `5554` (§7.4) | 2 | |
| `androidboot.modem_simulator_ports` | `9600` (§7.3) | 2 | capture |
| `androidboot.vsock_lights_{port,cid}`, `androidboot.vendor.audiocontrol.server.{port,cid}`, `androidboot.openthread_node_id` | capture values (§7.3) | 2 | guest-side servers |
| `androidboot.vsock_tombstone_port`, `androidboot.vhal_proxy_server_port`, `androidboot.auto_eth_guest_addr` | omitted (§7.3) | — | CF-13 |
| `androidboot.cuttlefish_service_bluetooth_checker` | `false` (§7.6) | 2 | CF-14 |
| `androidboot.enable_bootanimation`, `androidboot.enable_confirmationui`, `androidboot.setupwizard_mode` | `1`, `1`, `DISABLED` | 2 | capture |
| `androidboot.boot_devices` | `40000000.pci` (§5.3) | 3 | `VZPlatformProfile` |
| `androidboot.serialno` | `APKRUN` + first 10 hex digits of the instance UUID, upper case | 4 | |
| `androidboot.lcd_density` | 160 × backing scale of display 0 ([display-and-windowing.md](display-and-windowing.md)) | 4 | |
| `androidboot.ddr_size` | VM memory as `<MiB>MB`, for example `4096MB` | 4 | |
| `androidboot.apkrun.instance`, `androidboot.apkrun.devmode`, `androidboot.apkrun.image` | instance UUID; `0` or `1` (custom image only, §11.3); `imageVersion` | 4 | |
| `androidboot.apkrun.test.*` | test bundles only, never in release bundles (CI checks the release manifest): `marker=<value>` (§12.4), `fail_health=1`, `fail_boot=1` (init stops `zygote` before `sys.boot_completed`) | 2 | [diagnostics.md](diagnostics.md) §12 |

AVB metadata follows the top-level vbmeta chain in stored order. The digest covers each AVB0 header, authentication block, and auxiliary block, and excludes padding and footers. Chained partitions with their own footer are read through the vbmeta their footer declares. `hash_alg` follows the top-level algorithm (`NONE` uses SHA-256). `avb_version` follows the pinned AVB 1.4 toolchain. The hashtree policy is `restart_and_invalidate`, so `invalidate_on_error` is `yes`. `avb.py` rejects a top-level vbmeta with `VERIFICATION_DISABLED`.

### 6.3 Trailer and per-boot initrd

Layout: `[initrd][bootconfig text][NUL padding to 4 bytes][size: le32][checksum: le32]["#BOOTCONFIG\n"]`. `size` counts text and padding. `checksum` is the 32-bit sum of those bytes (`xbc_calc_checksum`). The cmdline must contain `bootconfig`.

Before every boot, ImageCore merges the layers, `clonefile`s `Images/<v>/boot/ramdisk.img` to `Runtime/instance/boot/initrd.img.tmp`, appends the trailer (copy-on-write), `fsync`s, renames to `initrd.img`, and records the text's SHA-256 in the boot record. `bootconfig.py` and `BootconfigWriter` share golden vectors in `Images/tools/tests/fixtures/bootconfig/`.

### 6.4 Kernel command line

`cmdline.txt` = vendor cmdline + boot cmdline + APKRun additions (`cmdline.additions` of the layout file):

- `console=hvc0`. crosvm adds it itself, so Cuttlefish images do not carry it. The VZ direct-kernel path requires it (ADR-0015).
- `log_buf_len=2M`. The default 256 KiB buffer wraps before the serial shell answers (CF-18).

No other reference-capture parameter is passed (CF-19). `androidboot.*` never goes on the cmdline. The total must fit the 2048-byte VM validation limit ([vm.md](vm.md) §3).

### 6.5 Verification on VZ

Checked on macOS 27.0.1 (26A434), build 16373615, Android kernel `6.12.74-android16-6-g3ec022196c4e-ab15076761-4k`.

- hvc0 starts when first-stage init loads `virtio_pci` and `virtio_console`, about 0.18 s in. Earlier lines (`Booting Linux on physical CPU`, `Kernel command line:`) never reach hvc0, so the init checks read them over the serial shell.
- The Linux test kernel (Alpine `linux-virt` 6.18.54) has no `CONFIG_BOOT_CONFIG`, so `/proc/bootconfig` does not exist there.
- A truncated ramdisk fails before `virtio_console` exists, so no panic text reaches hvc0. The boot ends with `bootStalled(kernel)`.

### 6.6 Init checks on VZ

`AndroidBootTests.testReachesInit` checks these on the product path (`RuntimeSupervisor` in developer mode, `AndroidShellConsole` over hvc1).

- **Ramdisk.** Only `boot/kernel` and `boot/ramdisk.img` are bundled. The build is `userdebug` with `ro.debuggable=1`.
- **fstab and partitions.** `androidboot.fstab_suffix=cf.f2fs.hctr2` selects `/vendor/etc/fstab.cf.f2fs.hctr2`: `/metadata` is `ext4` and `/data` is `f2fs`, both `rw`. First-stage init creates the non-empty logical partitions of slot `_a`, which mount read-only. `/dev/block/by-name` holds every label of §4.2.
- **AVB.** The unsigned vbmeta gives `OK_NOT_SIGNED` and `VerificationError` for `/system` and `/system_dlkm`. The boot continues with `verifiedbootstate=orange` (CF-16).
- **Bootconfig and SELinux.** `/proc/bootconfig` equals the merged block. `getenforce` is `Enforcing`, and dmesg has no AVC denial. No permissive workaround is set.
- **Logs and cmdline.** `log_buf_len=2M` keeps the first-stage lines in `dmesg` (CF-18). `/proc/cmdline` is the bootconfig key `kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size`, then the built-in command line, then `cmdline.txt`. The kernel logs `KVM is not available` (CF-17).
- **Devices.** `virtio_net`, `virtio_blk`, `virtio_console`, `virtio_rng`, `virtio_gpu`, and `vmw_vsock_virtio_transport` are bound, and `/dev/rtc0` exists.

---

## 7. Cuttlefish host-service substitution

Cuttlefish's guest expects host processes that APKRun does not run: the launcher, `secure_env`, `modem_simulator`, rootcanal, the GNSS proxy, the sensors simulator, `socket_vsock_proxy`, and others. This section states what APKRun provides instead. **Prefer in-guest implementations selected by configuration over host-side re-implementations.** Do not remove a guest service unless it breaks boot, stability, or resource use (#36).

### 7.1 Console port plan

Cuttlefish attaches 20 single-port virtio-consoles, and some HALs open fixed `/dev/hvcN` nodes, so the numbering must match. VZ accepts at most 10 single-port devices: ports 0–9 are single-port devices, and ports 10–19 are one multiport device, numbered hvc10–hvc19 in array order ([vm.md](vm.md) §6.1). No reordering is needed on VZ ([vm.md](vm.md) §6.2). The roles are `consolePorts` in the runtime manifest, and ImageCore turns them into `ConsolePortDefinition`s.

| Port | APKRun role (v1) |
|---|---|
| hvc0 | `.systemConsole` → `console.log` and `BootPhaseDetector` (`console=hvc0`) |
| hvc1 | `.silent("serial")`; `.service("serial")` for `apkrun dev console --android-shell` in developer mode |
| hvc2 | `.log("logcat")` in developer mode and after a failed boot (`guest/logcat-<timestamp>.log`, [diagnostics.md](diagnostics.md) §8.3); else `.silent` |
| hvc3, hvc4, hvc11 | `.silent`: keymaster, gatekeeper, and remote KeyMint are replaced in the guest (§7.2) |
| hvc18 | `.service("sensors")`: the "no sensors" responder (below) |
| hvc19 | `.silent`: kept open; with mask 0 the host never writes |
| hvc5–hvc10, hvc12–hvc17 | `.silent`: Bluetooth, GNSS, location, confirmationui, UWB, oemlock, NFC, Weaver, MCU, Ti50, JCardSim |

`.silent` ports are attached, so device nodes exist and opens succeed, but the host never writes. Leaving a port out is worse: a missing hvc10 (oemlock) or sensors port makes the HAL abort with `No such device` and crash-loop.

**Sensors responder.** The stock sensors HAL sends `list-sensors` on hvc18 and blocks for the reply, and registers `ISensors/default` only after it. A silent hvc18 blocks `system_server`, and no bootconfig key selects another implementation. RuntimeCore answers on hvc18, as the minimal adapter of [AGENTS.md](../../AGENTS.md) §15:

- Framing: a little-endian `u32` of `command | is_response << 31`, a little-endian `u32` payload size, then the payload.
- A payload starting with `list-sensors` gets command 2 (`kUpdateHal`) with `is_response` and payload `"0\n"` (`02 00 00 80 02 00 00 00 30 0a`), an empty sensor mask.
- Other messages (`time:`, `set-delay:`, `set:`) get no answer. The parser starts empty on every boot.

If VZ ever limits console devices further, attach ports 0–N in order, and the custom image points the affected HALs elsewhere or disables them.

### 7.2 Security HALs (KeyMint, Gatekeeper)

KeyMint is boot-critical (vold needs it for metadata and file-based encryption keys). Gatekeeper serves the lock screen and synthetic passwords. APKRun selects the **in-guest non-secure variants**, as `--secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure` does, with `androidboot.vendor.apex.<apex name>=<variant>`. Keys are software-backed. Attestation reports a software level and an unlocked device, and APKRun does not claim hardware-backed keys ([security-model.md](../01-architecture/security-model.md)). A host-side KeyMint on hvc11 is post-v1.

### 7.3 vsock services

| Service | Cuttlefish | APKRun |
|---|---|---|
| ADB | adbd on `vsock:5555`; `socket_vsock_proxy` bridges host TCP 6520 | `VsockLoopbackForwarder` bridges `127.0.0.1:6520` to vsock 5555 in developer mode only, never on another address ([vm.md](vm.md) §8). On custom images adbd runs only in developer mode (§11.3). |
| Guest `socket_vsock_proxy` 6520 → tcp 5555 | started by `init.vendor.rc` | left running; unused |
| Guest-to-host clients (tombstone, modem simulator, camera, vehicle HAL) | the matching `androidboot.*` keys | tombstone and vhal proxy keys omitted. `modem_simulator_ports=9600` stays: without it `radio-service.cf` restarts every 5 s; with it the RIL reports `RADIO_NOT_AVAILABLE`. |
| Guest-side servers (lights, audio control, OpenThread) | `vsock_lights_*`, `audiocontrol.server.*`, `openthread_node_id` | capture values stay; without them the HALs abort and init loops |
| APKRun agents | vsock 6100–6111 through `apkrun_vsockd` on custom images ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3) | |
| Substitutes | vsock 6120–6199 reserved; host-initiated only in v1 | guest-initiated use needs vsock listeners in `VMDefinition` and an ADR |

### 7.4 Network

Options, tried in order: **1.** a single NIC as Wi-Fi, which does not work with the stock image; **2.** several NAT NICs in Cuttlefish's order, which is verified and makes `VMDefinition.network` an ordered list ([vm.md](vm.md) §7); **3.** ethernet, custom image only. T2 checks: `ip addr`, a default route, DNS, `generate_204`, and `dumpsys connectivity` with a validated network.

Verified option 2 NICs:

| NIC | Guest name | Use | MAC |
|---|---|---|---|
| 0 | `eth0`, renamed `buried_eth0` by `rename_eth0` | mobile; unused without a modem | per instance |
| 1 | `eth1` | ethernet; the OpenThread HAL exits if it is missing | per instance |
| 2 | `eth2`, the `virt_wifi` backing NIC (`ro.vendor.virtwifi.port`) | Wi-Fi | `02:XX:YY:00:00:00`, `XXYY` = `androidboot.wifi_mac_prefix` (`5554` → `02:15:b2:00:00:00`) |

- `androidboot.wifi_impl=virt_wifi` makes `init.cutf_cvm.rc` run `setup_wifi`, which creates `wlan0` on `eth2`. The stock `mac80211_hwsim_virtio` path needs crosvm's Wi-Fi and an OpenWRT VM, which VZ lacks.
- `setup_wifi` rewrites `eth2`'s MAC from `wifi_mac_prefix`, because vmnet drops frames from a MAC it did not assign.
- Wi-Fi is off on a fresh `/data`. The first-boot settings join `VirtWifi` (§7.6).
- ICMP gets no reply through vmnet; TCP and UDP work. The validated Wi-Fi stage can be intermittent (R-12).

### 7.5 Audio

Cuttlefish passes virtio-snd, and the guest uses the AIDL audio HAL with `ro.hardware.audio.primary=goldfish`. APKRun attaches `VZVirtioSoundDeviceConfiguration` ([vm.md](vm.md) §11). #84 verifies the module, `/proc/asound/cards`, a host-audible test tone, and the logged format. If the stock image lacks `virtio_snd`, the custom image adds it (OQ-38). Microphone input: [vm.md](vm.md) §11.

### 7.6 Other guest expectations

| Area | Stock behaviour without host services | v1 handling |
|---|---|---|
| Input (vhost-user virtio-input) | none from Cuttlefish | Not reproducible on VZ; input goes through the Guest Agent ([input.md](input.md), ADR-0013) |
| Telephony (RIL) | stays up, `RADIO_NOT_AVAILABLE` (§7.3) | Accept; disable only if crash loops or CPU and log cost are measured |
| Bluetooth | `bt_hci` opens hvc5; the stack aborts about every 25 s until BluetoothManagerService gives up. The boot reporter then fails. | `cuttlefish_service_bluetooth_checker=false`; first-boot settings turn Bluetooth off. No Bluetooth in v1. |
| Sensors | HAL blocks boot unless hvc18 answers | "no sensors" responder (§7.1) |
| Camera | none | post-v1 |
| Battery, thermal | fixed values | keep |
| RTC, power button | PL031 (`/dev/rtc0`); PL061 presses on `requestStop` | keep; shutdown goes through the Guest Agent ([vm.md](vm.md) §9.3) |

**First-boot settings.** Wi-Fi is off and Bluetooth is on by default, and bootconfig cannot change that. After the first `.bootCompleted` of a fresh instance, RuntimeCore runs once: `cmd bluetooth_manager disable`, `cmd wifi set-wifi-enabled enabled`, and `cmd wifi connect-network VirtWifi open`. The settings persist in `/data`. The serial shell applies them in M1, the Guest Agent from M3. The custom image sets the defaults in its overlays.

### 7.7 Boot phase markers

The pinned Cuttlefish 1.57.0 host package uses the tokens `VIRTUAL_DEVICE_BOOT_STARTED`, `_BOOT_PENDING`, `_BOOT_COMPLETED`, `_BOOT_FAILED`, `_DISPLAY_POWER_MODE_CHANGED`, `_SCREEN_CHANGED`, `_NETWORK_ETHERNET_CONNECTED`, `_NETWORK_MOBILE_CONNECTED`, and `_NETWORK_WIFI_CONNECTED`.

- The guest's `GceEventReporter` writes `GceEventReporter: VIRTUAL_DEVICE_<TOKEN>` to the kernel log, so hvc0 shows them. `BOOT_STARTED` precedes `BOOT_COMPLETED`.
- `DISPLAY_POWER_MODE_CHANGED` lines carry `display=<n> mode=<state>`. Display-state and host failure lines are not boot-completion signals.
- `BootPhaseDetector` uses the tokens with `sys.boot_completed`: over ADB in M1, from the Guest Agent in M3 ([runtime-daemon.md](runtime-daemon.md)). Gate G2 requires `BOOT_COMPLETED` to be logged ([roadmap.md](../04-plan/roadmap.md) §2).

### 7.8 Verification

These facts hold on the test kernel and the stock image. Tests rely on them.

- The Linux test kernel creates `/dev/hvc0`–`/dev/hvc7` only, so the 20-port marker check skips at `/dev/hvc8`. The Android kernel creates `/dev/hvc0`–`/dev/hvc19`. Marker checks do not run on the Android guest, because host input attaches only to service ports.
- `testHostServiceSubstitutes` checks KeyMint and Gatekeeper registration, `/data`, and that logcat has no Weaver failure.
- The stock `system` partition has `ping` but no `getent`, `nslookup`, `dig`, `host`, `wget`, or `curl`. Only `ping` prints a name-resolution result.
- The serial shell runs as `uid=2000(shell)` in `u:r:shell:s0` and cannot reach `/dev/socket/dnsproxyd`, so its lookups fail at once. Root and app uids resolve. The SELinux fix belongs to #36 (§11.1, R-13).
- `AndroidNetworkTests` runs the name-resolution stage as root (`su 0 ping -c 1 -W 2 connectivitycheck.gstatic.com`) and judges each stage by its last polled value.

---

## 8. Reference boot capture

The reference boot is the ground truth for what U-Boot and the Cuttlefish launcher normally do. Every difference from a VZ boot must be explained (§8.4).

### 8.1 Reference host

Use an arm64 Linux machine with `/dev/kvm`, or an x86-64 Linux host running the arm64 image under QEMU TCG for a one-time capture. The host installs the Cuttlefish arm64 host tools and the same image build (§2). A nested-virtualization arm64 VM on Apple silicon is not usable: its guests ran far slower than on VZ and none reached `sys.boot_completed=1`. No complete reference boot therefore exists. The captures under `Images/reference/16373615/incomplete/` remain references for launcher outputs. Behaviour that needs a booted reference comes from the Cuttlefish source at `android17-release` and from the VZ boot.

### 8.2 Profiles

| Profile | `launch_cvd` flags | Purpose |
|---|---|---|
| `default` | defaults, `--cpus 4 --memory_mb 4096` | how stock Cuttlefish boots |
| `target` | `--gpu_mode=drm_virgl --secure_hals=guest_keymint_insecure,guest_gatekeeper_insecure --cpus 4 --memory_mb 4096` | the configuration APKRun reproduces on VZ |
| `swiftshader` | `--gpu_mode=guest_swiftshader` plus the `target` HAL flags | fallback GPU profile ([graphics.md](graphics.md) §9) |

- If the host cannot run `drm_virgl`, the operator selects `guest_swiftshader` with the variables of §8.3. `capture.sh` records `eglPlatform` (`surfaceless` for `drm_virgl`, else `null`).
- The mode that counts is `selectedGpuMode` from the instance configuration. Every profile passes `--gpu_vhost_user_mode=off` and requires `enable_gpu_vhost_user=false`, because Cuttlefish 1.57.0 enables the vhost-user backend on arm64, which does not support `drm_virgl`.
- The crosvm build in the tested host package omits `virgl_renderer`, and installing `libvirglrenderer` does not enable it. A `drm_virgl` capture needs a host package whose crosvm enables it.

### 8.3 What is captured

`Images/tools/reference/capture.sh <profile>` writes `Images/reference/<buildId>/<profile>/`. An abnormal exit moves the data to `incomplete/`. Guest commands are in `Images/tools/reference/guest-capture.txt`.

- **Host:** crosvm command line, `internal-bootconfig.txt` (AVB footer removed), `composite-disk-specs.json`, `cuttlefish_config.json`, `assemble_cvd.log`, `kernel.log`, `launcher.log`, `host-logcat.txt`, and `host.json` (GPU modes, `gpuVhostUserEnabled`, `eglPlatform`, tool hashes, no absolute paths).
- **Guest (`adb`):** `/proc/cmdline`, `/proc/bootconfig`, `getprop`, block devices, mounts and fstab, `dmesg`, `lsmod`, `/dev/hvc*` holders, `logcat -d -b all` (gzip), `lshal`, `service list`, network state, `/proc/asound/cards`, `getenforce`, AVC denials, and `VIRTUAL_DEVICE_*` markers.

Rules:

- Linux only, with Python 3.12 from `Images/tools/.venv`. Artifacts are verified against the checked-in manifest first. One capture runs at a time (host-wide lock), with no ADB device or crosvm process present.
- Instance 1 by default; `APKRUN_CVD_INSTANCE_NUM` selects another. Each run uses a private `HOME`. Guest commands go only to the instance's `localhost` serial. Shutdown waits up to `APKRUN_CVD_STOP_TIMEOUT_SECONDS` (120 s), then 10 s of forced stop.
- A failed collection is named in `MISSING.txt`. An incomplete capture moves to `incomplete/` and exits nonzero. A profile directory is never overwritten.
- Normalization redacts serial numbers, identifier arrays, MAC and EUI-64 addresses, host paths, and secrets. A capture must not contain secrets or user app data.
- `APKRUN_CAPTURE_BOOT_OBSERVER=1` writes `boot-observer.jsonl` during `cvd start`: bounded values only, with no raw output, PIDs, UIDs, tags, or package names (schema: `reference/boot_observer.py`).

### 8.4 Diff against the VZ boot

`Images/tools/reference/compare_boot.py <reference dir> <vz capture dir>` writes `report.json` and `report.txt` into the VZ capture directory. It compares normalized files in these categories: `cmdline`, `bootconfig`, `props`, `block devices`, `mounts`, `modules`, `HALs`, `hvc users`, `network`, and `SELinux`. The inputs are the files the capture tool writes under those names, such as `cmdline.txt`, `bootconfig.txt`, `block-by-name.txt`, `lshal.txt`, and `avc-denials.txt`.

- The comparison normalizes in memory and modifies neither input. An empty category on either side is a missing input.
- Every difference needs an exact `{category, key, reason, design}` entry in `Images/reference/<buildId>/expected-differences.yaml`. Unused entries are warnings. An unexplained difference exits 1. This is the verification of [ADR-0015](../01-architecture/decisions/0015-direct-kernel-boot.md).

### 8.5 Gate G2 verification

Gate G2 ([roadmap.md](../04-plan/roadmap.md) §2) requires five cold boots of the stock image on VZ, each reaching `sys.boot_completed=1` and staying up 10 minutes with no `system_server` restart, watchdog kill, or HAL crash loop. The reference diff of §8.4 after the last boot must have no unexplained difference. The gate test is `Tests/AcceptanceTests/G2AndroidBoot/`, which uses the `headless` profile (§9.1). The gate result is in [roadmap.md](../04-plan/roadmap.md) §2.

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
    public var manifest: RuntimeImageManifest
}

public actor ImageStore {
    public init(paths: APKRunPaths, trust: ImageTrustStore, diagnostics: Diagnostics)
    public var state: RuntimeImageState { get }       // state-machines.md §7
    public func current() throws -> InstalledImage
    public func previous() -> InstalledImage?
    public func install(from source: ImageSource) async throws -> InstalledImage   // .directory(URL) (development) | .archive(URL)
    public func verify(_ image: InstalledImage, depth: VerificationDepth) async throws  // .quick | .full
    public func setCurrent(_ version: ImageVersion) async throws                   // moves `previous`
    public func garbageCollect() async throws                                      // keeps current and previous
}

public actor InstanceStore {
    public func load() throws -> InstanceConfiguration?
    public func provision(image: InstalledImage, sizing: InstanceSizing) async throws -> InstanceConfiguration
    public func resetAndroid(image: InstalledImage) async throws                   // recreate disks from templates
    public func createRecoveryPoint(reason: RecoveryReason) async throws -> RecoveryPoint
    public func restore(_ point: RecoveryPoint) async throws
    public func recoveryPoints() -> [RecoveryPoint]
}

public struct AndroidBootPlanner: Sendable {
    public init(platform: VZPlatformProfile)
    /// Regenerates Runtime/instance/boot/initrd.img and returns the Android parts of the definition.
    public func prepareBoot(image: InstalledImage, instance: InstanceConfiguration,
                            options: BootOptions) throws -> AndroidBootPlan
}

public struct BootOptions: Sendable {
    public var gpuProfile: GPUProfileID               // .drmVirgl (default) | .guestSwiftshader | .headless (development only)
    public var developerMode: Bool
    public var captureLogcat: Bool
    public var soundOutput: Bool
    public var microphone: Bool
}

public struct AndroidBootPlan: Sendable {
    public var definition: VMDefinition              // customDevices empty; RuntimeCore adds the GPU device
    public var bootconfig: [BootconfigEntry]         // merged, with the layer of origin
    public var bootRecordID: UUID
}
```

`ImageSource`, `InstanceConfiguration`, `InstanceSizing`, `RecoveryPoint`, and `VZPlatformProfile` are `Codable` values defined next to these types.

`GPUProfileID.headless` is for bring-up only (`apkrun dev boot --gpu none`). It adds `VMDefinition.builtInDisplay` ([vm.md](vm.md) §4) and uses the `guest_swiftshader` keys, because the stock image needs a DRM device. Only development bundles list it, and `bundle` refuses to write it into a release-signed bundle ([graphics.md](graphics.md) §9; [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.3).

### 9.2 Field mapping

| `VMDefinition` field | Source |
|---|---|
| `label` | `"APKRun Android (" + imageVersion + ")"` |
| `cpuCount`, `memorySize` | `instance.json`, refreshed from `runtime.cpuCount` and `runtime.memoryGiB` before each boot ([vm.md](vm.md) §10) |
| `machineIdentifier` | `instance.json` |
| `boot` | `.linux(kernel:initialRamdisk:commandLine:)`: `Images/<v>/` + `boot.kernel.path`; `Runtime/instance/boot/initrd.img` (§6.3); `boot.cmdline` |
| `disks` | Manifest `disks`, then `templates`, in order (§4.2). The `os` disk is read-only, caching `.automatic`. Each template becomes the clone `Runtime/instance/<file name>`, read-write, synchronization `.full`. |
| `network` | Three `.nat(macAddress:)` entries in the order of §7.4 |
| `vsockEnabled`, `entropy`, `memoryBalloon` | `true` |
| `consolePorts` | Manifest `consolePorts`, roles adjusted by `BootOptions`, ordered by `ConsolePortPlan` ([vm.md](vm.md) §6.2) |
| `builtInDisplay` | Only for `GPUProfileID.headless` |
| `sound` | `SoundDefinition(output: options.soundOutput, input: options.microphone)` |
| `customDevices` | Empty. RuntimeCore appends the virtio-gpu device from GraphicsCore ([graphics.md](graphics.md)); ImageCore cannot depend on GraphicsCore ([modules.md](../01-architecture/modules.md) §3). |

### 9.3 Before every boot

1. `ImageStore.verify(current, .quick)`: steps 1–7 of [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.1. Results for steps 1–6 are cached per apkrund process, keyed by the inode, size, and modification time of `manifest.json`.
2. `InstanceStore.load()`: disks present with recorded sizes, and `imageVersion` equal to `current`. Otherwise a migration is pending (§12.3).
3. Compatibility: `minimumRuntimeVersion` ≤ the APKRun version, and the guest protocol range intersects `guestProtocol.majors` ([runtime-maintenance.md](runtime-maintenance.md) §2.1). Failures: `incompatibleRuntime(required)`, `incompatibleProtocol(range)`.
4. `AndroidBootPlanner.prepareBoot` writes the initrd and returns the plan.
5. RuntimeCore adds the GPU device and hands the definition to `VMController`.

---

## 10. Runtime image bundle

### 10.1 Contents

A bundle is the directory `Images/<imageVersion>/` with `manifest.json`, `manifest.sig`, `SHA256SUMS`, `boot/`, `disks/`, `templates/`, and `legal/`. The manifest blocks are in [runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4. `kind` is `stock` (from ci.android.com, development only) or `apkrun`. Unknown fields are rejected at every level.

- `manifest.sig` is an Ed25519 signature over the exact bytes of `manifest.json`. Its unsigned header holds the key ID: the first 8 bytes of SHA-256 over the raw public key, in hex.
- `ImageTrustStore` holds (key ID, public key) pairs. Release builds contain release keys only. Debug and test builds also contain the developer key from `python3 -m apkrun_image keygen`, which is never committed. An unknown key ID is `untrustedKey(keyID)`; a bad signature is `signatureInvalid(keyID)`.
- `SHA256SUMS` duplicates `files` for `shasum -a 256 -c`. It is unsigned, so ImageCore only checks that it matches `files`.
- Verification order ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §7.1): signature; schema; semantic rules S1–S14; the exact file set and sizes; then every hash for full verification. Extra files are rejected.
- Installed manifests are never rewritten. A newer schema than ImageCore knows fails with `manifestInvalid` ("needs a newer APKRun"). Host data such as `instance.json` is migrated instead ([runtime-maintenance.md](runtime-maintenance.md) §5).

### 10.2 Build command

```bash
python3 -m apkrun_image bundle \
  --manifest Images/manifests/16373615/android-image.json \
  --layout   Images/tools/layouts/cuttlefish-phone-arm64.json \
  --reference Images/reference/16373615/target \
  --image-version 2026.10.0 --sign-key ~/.config/apkrun/dev-image-key \
  --out Images/work/16373615/bundle/
```

- `bundle` runs extract, disks, and the bootconfig baseline. It writes `boot/bootconfig.txt` (`[vendor]` from `vendor-bootconfig.txt`, `[image]` from the layout and `avb.py`), then the manifest, `SHA256SUMS`, and the signature. The version gets the base suffix (`-cf16373615-arm64`).
- The build is deterministic (fixed GUIDs, no timestamps, sorted keys). CI builds the fixture bundle twice and compares `SHA256SUMS` (T1).
- `--sign-key` is required. The unsigned path (`--unsigned`, `DevelopmentImage`, `apkrun dev boot --bundle`) is removed. `apkrun dev boot` boots `current` ([cli.md](cli.md) §5).

### 10.3 Development install

`apkrun dev image install <bundle>` asks apkrund (or the embedded runtime) to install a directory. ImageCore verifies it, `clonefile`s it into `Images/.installing-<version>/`, renames it to `Images/<version>/`, and sets `current`. If there is no instance, it provisions one. The installed tree is read-only ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §3.1).

### 10.4 Release packaging and distribution

- **Archive.** The release pipeline packs a release-signed bundle with `aa archive -a lzfse` into `<imageVersion>.aar` ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §8.1).
- **Feed.** A signed index per channel (`stable`, `beta`) lists versions, archive URLs, sizes, SHA-256s, requirements, and rollout, with a sequence number and an expiry ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §9). The host depends on OQ-01. `feed.json.sig` uses the `manifest.sig` format.
- **Download and install.** Downloads resume with `Range` into `Cache/images/`, after free-space checks for archive size plus `expandedSize` plus 10 GiB ([runtime-maintenance.md](runtime-maintenance.md) §4.4). The feed SHA-256 is checked. The archive is extracted under the entry rules of [runtime-maintenance.md](runtime-maintenance.md) §4.5 into `Images/.installing-<name>/`, gets full verification, and for a feed install must match the feed entry. Holes are punched in `disks/` and `templates/` (`fcntl(F_PUNCHHOLE)` over all-zero 1 MiB blocks), and the directory is renamed into place. Installing changes neither `current` nor `previous`. An interrupted install leaves only `.installing-*`, deleted at startup.
- **UX.** "Android system update ready". It is applied when the Mac is idle or the user clicks, never during active sessions without the user's agreement ([runtime-maintenance.md](runtime-maintenance.md) §4.6).

---

## 11. APKRun AOSP product

The guest agents are designed in [guest-components.md](guest-components.md). This section covers the image. Development images are composed from the stock build on the Mac (§11.5, #36). Release images are built from source (§11.6, #120). Both take the product files from `Guest/product/` ([ADR-0019](../01-architecture/decisions/0019-composed-development-image.md)).

### 11.1 Product definition

The source is `Guest/product/`. The composer reads its placement list `compose.json` (§11.5). A source build maps it into the AOSP tree as `device/apkrun/apkrun_arm64/`. It contains `compose.json`, `AndroidProducts.mk` (lunch targets `apkrun_arm64-trunk_staging-userdebug` and `-user`), `apkrun_arm64.mk` (inherits `device/google/cuttlefish/vsoc_arm64_only/phone/aosp_cf.mk`; `PRODUCT_PACKAGES += apkrun_vsockd ApkRunGuest ApkRunStore`), `Android.bp` (agent APKs with the platform certificate, privileged, in `/system_ext/priv-app`), `prebuilt/` (git-ignored agent APKs copied by `scripts/build-guest.sh`), `init/apkrun.rc`, `sepolicy/` (CIL fragments), `permissions/`, `overlay/`, `settings/`, and `manifest/pinned.xml` (the `repo manifest -r` snapshot for release builds).

- The policy is CIL, the form of the image's split policy. Its types are `system_ext` types. How a source build carries the CIL into Soong is decided by #120.
- In a source build, `PRODUCT_IGNORE_ALL_ANDROIDMK := true`: all modules use `Android.bp`. The base product uses a 16 KiB page size, which the Rust and Kotlin components do not assume.
- `ro.apkrun.product=1`, plus the default profile's GPU properties. `bundle --image-version` sets the image version, and ImageCore passes `androidboot.apkrun.image` at every boot.
- `Guest/product/mesa/` (#99) holds the pinned EGL, GLES, and Gallium prebuilts, staged by `scripts/guest/stage-mesa-product.sh`. It supplies neither the product nor a SELinux policy.
- The guest loads `/odm/etc/selinux/precompiled_sepolicy`, not the `/sepolicy` of the boot ramdisk. The composer compiles a new ODM policy from the split inputs (§11.5). A sysfs label comes from `genfscon`, so a vendor `file_contexts` entry cannot change it.
- The virtio-gpu PCI nodes under `/sys/devices/platform/40000000.pci/` carry the default `sysfs` label. On the `odm4` bundle the launcher (`priv_app`) and Settings (`system_app`) fail Mesa's DRM probe, while platform and untrusted apps pass. The untested candidate is a `genfscon` label `sysfs_gpu` on that path, plus a decision on `system_app` (R-13).

### 11.2 What the product changes, and what it does not

| Change | Why |
|---|---|
| Adds the Guest Agent, Store Agent, `apkrun_vsockd`, their sepolicy and privapp permissions | production control path ([ADR-0008](../01-architecture/decisions/0008-guest-agents.md)) |
| Defaults KeyMint and Gatekeeper to the in-guest APEX variants; adds `virtio_snd` if missing | §7.2, §7.5 |
| `Settings.Global.AUTO_TIME = 0`, `AUTO_TIME_ZONE = 0` | the host is the only time source ([desktop-integration.md](desktop-integration.md) §9) |
| Adds an in-Android browser (AOSP `Browser2`) if the base has none | "Keep in Android" for links ([desktop-integration.md](desktop-integration.md) §7.1) |
| Multi-display and freeform overlays | [display-and-windowing.md](display-and-windowing.md) |
| Disables a HAL or service only with evidence from the §7 checks (#96) | "Do not aggressively remove services" (#36) |
| Does **not** change the kernel, partition layout, or fstab | the stock image stays a valid development target |

### 11.3 Developer mode on custom images

- `androidboot.apkrun.devmode=1` makes `init/apkrun.rc` start adbd on vsock 5555 (trigger `ro.boot.apkrun.devmode`). With `0`, the default, `apkrun.rc` stops adbd even in a userdebug build. #36 verifies that no other trigger restarts it.
- `user` builds have `ro.adb.secure=1`. The Guest Agent authorizes the host's ADB key with `AdbManager.allowDebugging` (needs `MANAGE_DEBUGGING`), so no dialog appears on an unseen display.
- A change of the devmode setting takes effect at the next runtime start, like the microphone setting.

### 11.4 Variants and verified boot

| Build | Variant | AVB state |
|---|---|---|
| Development | the stock `userdebug` build, composed (§11.5; M5 onward, CI); AOSP test keys | `orange`, unlocked |
| Release | `user`, built from source with APKRun release keys (§11.6) | open (OQ-36) |

Proposed for release: pass `orange` and unlocked, but keep dm-verity on through the vbmeta hashtree descriptors. The guest has no bootloader, so it cannot establish a hardware root of trust. The integrity chain is host-side: signed manifest, file hashes, then `os.img` read-only. Claiming `green` would misstate the device state.

### 11.5 Composition (development images)

`python3 -m apkrun_image compose` (#36) makes the development image from the pinned stock build, on the developer Mac ([ADR-0019](../01-architecture/decisions/0019-composed-development-image.md)).

- **Placement.** Every added file is listed in `Guest/product/compose.json` with its image path, mode, owner, and SELinux label. Added files go into `system_ext_a`. The composer exports the stock tree, adds the files, rebuilds the EROFS image (§4.6), and checks that every stock entry is unchanged.
- **Growth.** `system_ext_a` has no free space. The composer grows it in the super metadata inside its group (`google_system_dynamic_partitions_a`), and refuses to exceed the group's maximum size. No other partition moves.
- **Policy.** The CIL fragments are added to `system_ext_sepolicy.cil`, and the entries to `system_ext_seapp_contexts` and `system_ext_file_contexts`. A pinned `secilc` compiles `precompiled_sepolicy` from the same inputs as `init`, and the composer writes the matching SHA-256 files into `odm_a`. `secilc` enforces `neverallow`.
- **Signing.** The agents are signed with the public AOSP test platform key (certificate SHA-256 `c8a2e9bc…2ab8`), which `seinfo=platform` of the stock build names. The hashtrees and FEC are rebuilt with the pinned avbtool, and `vbmeta_system_a` and `vbmeta_a` are re-signed with the AOSP AVB test key (§4.6).
- **Bundle.** `kind: apkrun`, with the stock build and the composition inputs in `provenance` ([runtime-image-manifest.md](../03-reference/runtime-image-manifest.md) §4.3). A composed bundle contains the stock build, so it is never published ([legal-and-licensing.md](../05-development/legal-and-licensing.md) §2).
- **Limits.** No `user` variant, no kernel or module change, and no release keys. Those need §11.6.
- Acceptance (#36): the composed image reaches `boot_completed`, the agents start, and the reference diff has no unexplained differences beyond the documented product changes.

### 11.6 Release build

This is the plan for #120, which may instead re-sign the CI target files ([ADR-0019](../01-architecture/decisions/0019-composed-development-image.md)).

- The host is x86-64 Linux with 64 GB of RAM and 400 GB of disk ([environment-setup.md](../05-development/environment-setup.md) §5). macOS cannot build AOSP.
- `repo init` with the pinned manifest, `repo sync`, `lunch apkrun_arm64-trunk_staging-userdebug`, `m`, `m dist DIST_DIR=out/dist` with `BUILD_NUMBER=ar<counter>` (`scripts/aosp/build-product.sh`). The `*-img-*.zip` goes through §3–§10.
- `provenance` records the pinned manifest, the builder image digest, and the `Guest/` git revision.
- Acceptance (#120): the image passes the suites of the composed image, and no AOSP test key signs it.

---

## 12. Versioning, compatibility, and migration

### 12.1 Versions and compatibility

- `imageVersion` is `YYYY.MM.N-<base>-<arch>`, compared on (YYYY, MM, N). APKRun never installs a lower version automatically.
- `requirements.minimumRuntimeVersion` is the oldest APKRun host that may boot the image. `requirements.guestProtocol` must intersect the host's range ([guest-protocol.md](guest-protocol.md)).
- `userdata.schemaVersion` is APKRun's integer for the layout of `/data` and `/metadata`. Images list the schemas they can boot in `userdata.upgradableFrom`. Android cannot downgrade `/data`, so a lower schema is refused unless the user chooses "Reset Android".

### 12.2 Recovery points

`InstanceStore.createRecoveryPoint` writes `Runtime/instance/recovery-points/<timestamp>-<imageVersion>/` with `clonefile` copies of `userdata.img` and `instance.json`. The VM must be stopped. After a successful migration only the newest point is kept.

### 12.3 Migration A → B

ImageCore provides the data steps. RuntimeCore's `RuntimeSupervisor` runs the boot and health check.

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

Crash safety: `migration` lives in `Runtime/instance/instance.json` and is written before step 3 changes anything. It is removed only by the last write of 6a or 6b. Every `instance.json` write is `fsync`ed and renamed into place, and the `current` and `previous` symlinks are replaced the same way. If apkrund finds a `migration` with no VM running, it treats the migration as failed and runs 6b, because the health result is unknown. 6b always restores R from the start.

Errors (§14.1): `incompatibleRuntime`, `incompatibleProtocol`, `userdataSchemaUnsupported`, `migrationSourceTooOld`, `downgradeRejected`, and `insufficientSpace` for failed preconditions; `migrationHealthFailed(report)` for 6b; `migrationInterrupted` at startup. A manual rollback after success restores R and loses data written since the migration, so the UI asks for confirmation.

### 12.4 Acceptance test

A T2 test uses bundle A, and bundle B = A with `androidboot.apkrun.test.marker=B` and a higher version.

1. Provision with A, install HelloText, and increment its persistent counter.
2. Migrate to B. Expect `installed(B)`, `ro.boot.apkrun.test.marker` equal to `B`, HelloText present, and its counter preserved.
3. Build B′ with `androidboot.apkrun.test.fail_health=1`. Migrate B to B′. Expect `installed(B)` after the automatic restore, B′ rejected, and HelloText's data intact.

---

## 13. Deviations from standard Cuttlefish

Each deviation has an ID with the prefix `CF-`. `Images/reference/<buildId>/expected-differences.yaml` is the machine-checked list (§8.4). New rows are added when a difference is found.

| # | Deviation | Reason | Section |
|---|---|---|---|
| CF-01 | No U-Boot; direct kernel boot with a pre-assembled initrd and bootconfig | VZ boot loaders; ADR-0015 | §4.1, §6 |
| CF-02 | Slot `_a` only | no OTA | §4.2 |
| CF-03 | No `uboot_env`, persistent vbmeta, or `bootconfig` partitions | U-Boot only | §4.2 |
| CF-04 | Raw GPT images, not crosvm composite disks: `os.img` and `userdata.img`, no sdcard disk | VZ attaches files; a third disk would be `sdcard1` | §4.2 |
| CF-05 | `boot_devices` is `40000000.pci`, not `10000.pci` | platform difference | §5.3 |
| CF-06 | Blank userdata, formatted at first boot | clean instances; no host f2fs tools on macOS | §5.2 |
| CF-07 | In-guest non-secure KeyMint and Gatekeeper | no `secure_env` host process | §7.2 |
| CF-08 | Most hvc ports are silent; hvc10–hvc19 are one multiport device | VZ allows 10 single-port consoles | §7.1 |
| CF-09 | No vhost-user input; input goes through the Guest Agent | not reproducible on VZ | §7.6 |
| CF-10 | virtio-gpu is APKRun's custom VirGL device; `headless` uses VZ's 2D virtio-gpu | VZ custom virtio API; the stock image needs a DRM device | [graphics.md](graphics.md) §9, §9.1 |
| CF-11 | Three VZ NAT NICs in Cuttlefish's order; Wi-Fi through `virt_wifi` on `eth2` | VZ has no virtio Wi-Fi; vmnet filters source MACs | §7.4 |
| CF-12 | No modem, rootcanal, GNSS, or camera hosts; "no sensors" responder on hvc18 | out of v1 scope; the sensors HAL blocks `system_server` | §7.1, §7.6 |
| CF-13 | Host-side client keys dropped; guest-side server keys stay | no host services | §6.2, §7.3 |
| CF-14 | `cuttlefish_service_bluetooth_checker=false`; first-boot settings: Bluetooth off, Wi-Fi on | no rootcanal; Wi-Fi defaults off | §7.6 |
| CF-15 | `androidboot.console=hvc1` and `serialconsole=1` in developer mode | the serial shell is the debug channel before ADB | §6.2 |
| CF-16 | AVB reports `OK_NOT_SIGNED` and `VerificationError`; boot continues with `orange` | development vbmeta is unsigned | §6.6 |
| CF-17 | The kernel logs `KVM is not available. Ignoring kvm-arm.mode` | VZ does not expose pKVM | §6.6 |
| CF-18 | `log_buf_len=2M` is added | the default buffer wraps before the serial shell answers | §6.4, §6.6 |
| CF-19 | The reference cmdline has `earlycon`, `ramoops.*`, and a second `panic=-1`; none is passed on VZ | crosvm's UART and ramoops do not exist on VZ | §6.4, §6.6 |

#36 adds the product changes of §11.2 that differ at runtime, such as the developer-mode gate of adbd (§11.3).

---

## 14. Errors, logging, health

### 14.1 `ImageFailure` (error domain `image`)

Each case has a code, user text, and remediation in [error-catalog.md](../03-reference/error-catalog.md).

- Integrity: `manifestInvalid(path, reason)`, `signatureInvalid(keyID)`, `untrustedKey(keyID)`, `unexpectedFile(file)`, `hashMismatch(file)`, `missingFile(file)`.
- Store: `imageNotInstalled(version)`, `noCurrentImage`, `downgradeRejected(from, to)`, `insufficientSpace(required, available)`, `cloneUnsupported(volume)`, `cloneFailed(errno)`.
- Compatibility: `incompatibleRuntime(required)`, `incompatibleProtocol(range)`, `userdataSchemaUnsupported(instance, image)`, `migrationSourceTooOld(minimum)`.
- Instance and boot: `instanceMissing`, `instanceCorrupt(reason)`, `recoveryPointMissing`, `bootconfigConflict(key, layerA, layerB)`, `bootconfigTooLarge(size)`, `cmdlineTooLong(length)`.
- Migration: `migrationHealthFailed(report)`, `migrationInterrupted`.

### 14.2 Logging

Subsystem `io.apkrun.image`, categories `store`, `install`, `verify`, `instance`, `boot`, and `migration`. Each boot logs the image version, the bootconfig hash, and the disk identifiers. `androidboot.serialno` and the instance UUID are redacted in diagnostics bundles ([diagnostics.md](diagnostics.md) §6).

### 14.3 Health checks (`apkrun doctor`)

| Check | Pass condition |
|---|---|
| `image.current` | `current` exists and passes quick verification (`--deep`: full hashes) |
| `image.instance` | disks present with recorded sizes; `imageVersion` consistent |
| `image.freeSpace` | at least 10 GiB free on the Application Support volume (warning below) |
| `image.kind` | warning `image.developmentImageInUse` when a `stock` image is the runtime |
| `image.recoveryPoint` | at most one; none left from a failed migration older than 7 days (warning `image.recoveryPointStale`) |
| `image.migration` | no migration stuck in `migrating` |

---

## 15. Tests

| Tier | What is tested | Where |
|---|---|---|
| T0 Python | inventory classification; manifest schema and semantic checks; sparse decoder; GPT round trip; bootconfig golden vectors; kernel decompression | `Images/tools/tests/` |
| T0 Swift | `ImageVersion` ordering; manifest decoding; bootconfig merge conflicts; GPT backup relocation; `VMDefinition` mapping (§9.2) | `Packages/ImageCore/Tests/ImageCoreTests/` |
| T1 | Pipeline on synthetic fixtures, built twice with identical `SHA256SUMS`; install, hole punching, signature and extra-file rejection; provisioning and `clonefile`; recovery points | `Images/tools/tests/`; `Packages/ImageCore/Tests/ImageCoreTests/` |
| T2 | Linux test guest disks and `/proc/bootconfig`; stock boot, init, `sys.boot_completed`, ADB; 20-port numbering; hvc roles; migration (§12.4) | `Tests/IntegrationTests/LinuxGuestTests/`, `…/AndroidBootTests/`, `…/AndroidADBTests/` |
| T3 | Gate G2 (§8.5) | `Tests/AcceptanceTests/G2AndroidBoot/` |

---

## 16. Open items

- Release variant: signing and the AVB state (§11.4). OQ-36.
- Hosting of the image feed and archives (§10.4). OQ-01.
- Archive extraction writes zero runs before holes are punched (§10.4). R-25.
- Licensing of redistributed images (§2.3). R-10, #94.
- SELinux for the vsock bridge, the agents, and the virtio-gpu sysfs label (§11.1). R-13, #36.
- AOSP build infrastructure and upstream changes (§11.6). R-14, #120.
- Differences between the composed image and a source build (§11.5). R-26, #120.
- `virtio_snd` in the stock kernel (§7.5). OQ-38, #84.
- Intermittent Wi-Fi and name resolution (§7.4, §7.8). Pending: marker checks of 20 ports on the Android kernel, and the RIL's CPU and log cost. R-12, #96.
- `androidboot.boot_devices` `40000000.pci` across macOS builds (§5.3). R-16.
- `drm_virgl` graphics properties (§6.2) come from source only. No capture or VZ boot confirms them. No OQ or R row covers this yet.

---

## 17. Verification

This document keeps no run records. Evidence is in commit messages and pull requests ([README](../README.md) §3). Open items are in §16.
