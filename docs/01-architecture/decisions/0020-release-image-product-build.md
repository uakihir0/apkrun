# 0020. Release images are built from AOSP source and signed with APKRun keys

- Status: Accepted
- Date: 2026-11-22
- Related: #120, ADR-0003, ADR-0011, [../../02-design/android-image.md](../../02-design/android-image.md) §2.3, §11.4–§11.5, [../../05-development/build-system.md](../../05-development/build-system.md) §9, [../../04-plan/risks.md](../../04-plan/risks.md) R-13, R-14, OQ-36

## Context

Development custom images are composed on the developer Mac from the pinned stock Cuttlefish build ([ADR-0019 on task/36](https://github.com/uakihir0/apkrun/blob/task/36-composed-image/docs/01-architecture/decisions/0019-composed-development-image.md), pending merge). #120 needs a *release* image, and [android-image.md](../../02-design/android-image.md) §2.3 forbids publishing a stock Google-built image or anything derived from it. Two candidate routes were open:

1. The **AOSP product build** of [android-image.md](../../02-design/android-image.md) §11.4, §11.5: `repo` sync of the pinned manifest on the Linux builder, `lunch apkrun_arm64-trunk_staging-user`, `m dist`, then `sign_target_files_apks` with the APKRun platform and release keys.
2. **Re-signing CI target files** with `sign_target_files_apks` and `add_img_to_target_files`: take the pinned `cf_arm64_only_phone` target-files zip, re-sign it, rebuild the image zip.

OQ-36 also asks which AVB state the release bootconfig passes and whether dm-verity stays on.

## Decision

1. **Release images come from the AOSP product build, not from re-signing CI artifacts.** `scripts/aosp/build-product.sh` builds `apkrun_arm64-trunk_staging-user` from the pinned manifest and signs the target files with the APKRun keys. Re-signing CI target files would still ship the prebuilt stock build under a new signature, which [android-image.md](../../02-design/android-image.md) §2.3 forbids, and it cannot produce a `user` variant without AOSP test keys somewhere in the chain.
2. **`Guest/product/` is the single source** for what the product adds, on both routes: the development composer reads its placement list, and the product build maps it to `device/apkrun/apkrun_arm64/` and builds it with Soong (`AndroidProducts.mk`, `apkrun_arm64.mk`, `Android.bp`). The SELinux policy is written once as CIL fragments: `userdebug` also compiles `userdebug_permissive.cil`, and `user` builds reject any `permissive` domain through `scripts/check-sepolicy.sh` (R-13).
3. **OQ-36 is settled as proposed** in [android-image.md](../../02-design/android-image.md) §11.4: the release bootconfig passes `androidboot.verifiedbootstate=orange` and `androidboot.vbmeta.device_state=unlocked`, and dm-verity stays on through the vbmeta hashtree descriptors. The guest has no bootloader to establish a hardware root of trust; claiming `green`/`locked` would misstate the device state. The integrity chain is host-side: signed feed → signed manifest → file hashes → `os.img` attached read-only.
4. **Keys.** APKRun release keys are generated once on the signing machine and kept outside the repository (AVB release key for vbmeta, platform/release keys for APK signatures via `sign_target_files_apks`). No AOSP test key signs any part of a `user` image; `build-product.sh` fails if a test-key signer is detected in the signed target files.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Re-sign CI target files (`sign_target_files_apks` on the stock build) | Still distributes the prebuilt stock build ([android-image.md](../../02-design/android-image.md) §2.3), keeps `userdebug` artifacts, and gives no path to remove AOSP test-key signatures from priv-apps |
| Publish the composed development image | Explicitly rejected by ADR-0019: it contains the stock build and test-key signatures; it is never published |
| `green`/`locked` AVB state | The guest has no bootloader and no hardware root of trust; the locked state would be a claim nothing verifies |

## Consequences

- A release image needs the Linux builder ([environment-setup.md](../../05-development/environment-setup.md) §5) and the pinned `repo` manifest (R-14 mitigation). `Guest/product/manifest/pinned.xml` is produced by `repo manifest -r` on the builder at the first pin and committed.
- The `user` build's policy is checked before `lunch`: `scripts/check-sepolicy.sh --variant user` fails when a permissive statement or the `userdebug_permissive.cil` fragment reaches the build.
- OQ-36 is closed. R-13 stays open until the permissive-mode denial audit lands the final rules; R-14 stays open with the pinned-manifest mitigation in place.
