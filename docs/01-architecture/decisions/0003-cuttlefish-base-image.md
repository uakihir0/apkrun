# 0003. AOSP Cuttlefish arm64 as the guest base

- Status: Accepted
- Date: 2026-09-28
- Related: #008–#017, #035, #064, #065, #095, [../../02-design/android-image.md](../../02-design/android-image.md)

## Context

We need an Android build for arm64 that runs in a generic virtio VM. Candidates are Cuttlefish (AOSP's virtual device for crosvm/QEMU), goldfish/ranchu (the Android Emulator's device), or a from-scratch device.

Research (2026-09-28):

- Prebuilt `aosp_cf_arm64_only_phone-userdebug` images are published on ci.android.com (branch `aosp-android-latest-release`). The image zip contains boot, init_boot, and vendor_boot (v4), vbmeta*, a sparse `super.img`, and a sparse `userdata.img`.
- Cuttlefish uses virtio devices exclusively (virtio-blk, virtio-net, virtio-gpu, virtio-console, vsock, virtio-snd). It has a `drm_virgl` GPU mode (Mesa VirGL, minigbm gralloc, ranchu HWC in client mode, DRM display finder, GLES 3.0).
- It normally boots through U-Boot and relies on host-side services on virtio-console ports (hvc1–hvc19: keymint, gatekeeper, …) and on vhost-user input devices.
- The host package binaries are Linux ELF (not usable on macOS). The `device/google/cuttlefish` tree on AOSP main stopped moving in 2025-03. The `android17-release` branch is current.

## Decision

Base the guest on **Cuttlefish arm64 (`vsoc_arm64_only`, phone config)**:

1. **M1–M4:** boot the stock prebuilt image under VZ (direct kernel boot, [0015](0015-direct-kernel-boot.md)) for development.
2. **M5+:** build our own product `apkrun_arm64`, which inherits `vsoc_arm64_only/phone/aosp_cf.mk` and adds the APKRun agents, the vsock bridge, sepolicy, properties, and settings, on a remote Linux x86-64 build host.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| goldfish/ranchu (emulator images) | Tied to QEMU's goldfish devices and the emulator's host pipes (qemud, gfxstream pipe). More non-virtio devices to emulate |
| A from-scratch device | Too much board bring-up for no benefit |
| Android-x86 / Bliss / Waydroid images | Not arm64 or not AOSP-current, and a weaker update story |

## Consequences

- We must reproduce, without U-Boot and without the Cuttlefish host daemons, everything the guest expects. The ground truth comes from a reference boot on Linux (#064). Missing host services (keymint/gatekeeper over hvc) are handled in the custom image by selecting in-guest implementations (R-12).
- AOSP builds need an x86-64 Linux host with ≥ 64 GB RAM and 400 GB disk. macOS cannot build AOSP ([../../05-development/environment-setup.md](../../05-development/environment-setup.md) §5).
- Cuttlefish input devices (vhost-user) cannot be reproduced. Input goes through guest injection ([0013](0013-input-via-guest-injection.md)).

## Verification

G2 (Android reaches `boot_completed`) with the stock image (#012–#014), then again with the custom image (#035).
