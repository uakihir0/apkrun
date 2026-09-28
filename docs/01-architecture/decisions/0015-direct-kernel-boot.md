# 0015. Direct kernel boot without a bootloader

- Status: Accepted
- Date: 2026-09-28
- Related: #009–#015, #064, #065, R-11, R-12, [../../02-design/android-image.md](../../02-design/android-image.md)

## Context

Cuttlefish under crosvm boots through U-Boot (`bootloader.crosvm`). U-Boot:

- reads the misc partition (`bcb load`),
- chooses the A/B slot and sets `androidboot.slot_suffix`,
- verifies vbmeta (libavb) and passes `androidboot.vbmeta.*` and `androidboot.verifiedbootstate`,
- loads boot, init_boot, and vendor_boot,
- concatenates vendor ramdisks + the generic ramdisk + bootconfig (from a `bootconfig` partition) and boots the kernel.

VZ's arm64 path offers `VZLinuxBootLoader` (kernel `Image` + initrd + cmdline) or EFI (`VZEFIBootLoader`). First-stage init creates `/dev/block/by-name/*` only for devices on the paths listed in `androidboot.boot_devices`.

## Decision

Use **`VZLinuxBootLoader`** with artifacts pre-assembled by the runtime image pipeline:

- Kernel: uncompressed `Image`, extracted from `boot.img`. The kernel is gz/lz4-decompressed at build time.
- initrd: `vendor_boot` ramdisk fragments (in table order) + `init_boot` generic ramdisk, concatenated at build time into `ramdisk.img`, + one **bootconfig trailer**. The build writes the vendor and image bootconfig layers to `bootconfig.txt`. Before every boot ImageCore merges them with the platform layer (`androidboot.boot_devices`) and the instance layer (serial number, lcd density, memory size) and appends a single trailer, because the kernel reads exactly one bootconfig block ([../../02-design/android-image.md](../../02-design/android-image.md) §6.1, §6.3).
- cmdline: the `vendor_boot` cmdline + `console=hvc0` + keys captured from the reference boot that U-Boot/crosvm would have added.
- The bootconfig must contain everything U-Boot would have provided:
  - `androidboot.slot_suffix=_a`
  - `androidboot.boot_devices=<VZ PCI host path>`
  - `androidboot.verifiedbootstate=orange`
  - `androidboot.vbmeta.{device_state,digest,hash_alg,size,avb_version}`
  - `androidboot.force_normal_boot=1`, if the reference shows it
- Disks: raw GPT images whose partition names match Cuttlefish's `os_composite`, so by-name links and fstab entries match ([../../02-design/android-image.md](../../02-design/android-image.md) §4).
- Slot `_a` only. A/B updates of the guest image are done by replacing the image, not by in-guest OTA.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Run U-Boot (EFI build) via `VZEFIBootLoader` | Needs a U-Boot EFI port for the VZ platform plus its env and misc handling. More moving parts. It stays a fallback if direct boot proves insufficient (R-11) |
| crosvm U-Boot image | crosvm-specific (it expects crosvm's device tree/MMIO layout). VZ is PCI ECAM with DT |

## Consequences

- We own "bootloader semantics": no in-guest OTA, no slot switching, and no recovery boot (recovery-as-boot is not supported).
- The VZ PCI host path for `boot_devices` must be discovered empirically (#011: boot any Linux and read `/sys/bus/pci/devices` and `/sys/devices/platform`), because Apple doesn't document it. `androidboot.boot_part_uuid` is an alternative if the path isn't stable.
- AVB: userdebug images are unlocked (orange). For production images we either keep AVB in "unlocked" mode with dm-verity still on, or compute vbmeta digests at build time and pass them via bootconfig. This is settled in #035.

## Verification

#012–#014 reach `sys.boot_completed=1` (G2). #064's reference capture is diffed against the VZ boot (`/proc/cmdline`, `/proc/bootconfig`, `getprop`) with no unexplained differences.
