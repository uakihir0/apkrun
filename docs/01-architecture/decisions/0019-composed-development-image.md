# 0019. Development custom image composed from the stock Cuttlefish build

- Status: Superseded by 0020
- Date: 2026-10-23
- Approval: the project owner approved this route in the session of 2026-10-23, instead of an AOSP product build for development images.
- Related: #36, #37, #120, ADR-0003, ADR-0008, ADR-0011, ADR-0018, R-13, R-14, OQ-36, [../../02-design/android-image.md](../../02-design/android-image.md) §4.6, §11

## Context

#36 planned the custom image as an AOSP product build (`apkrun_arm64-trunk_staging-userdebug`) on a Linux x86-64 builder with 64 GB of RAM and 400 GB of disk. No such builder exists, so #36 cannot start, and every task that needs the custom image waits for it: #37, the M6 update tests, and #55, #82, #83, #86.

The development image needs the stock build plus a few added files: two priv-apps, one native binary, init and permission files, and SELinux policy. It needs no change to the kernel, the partition layout, or fstab (android-image.md §11.2). The stock build 16373615 allows these additions after the build:

- It is `userdebug/test-keys`. The `platform` signer in `plat_mac_permissions.xml` has the certificate SHA-256 `c8a2e9bccf597c2fb6dc66bee293fc13f2fc47ec77bc6b2b0d52c11f51192ab8`, the public AOSP test platform key. An APK signed with that key is a platform-signed app on this image.
- `vbmeta_a` and the chained `vbmeta_system_a` are signed with the AOSP AVB test key `2597c218…`, which the repository already pins for development variants (android-image.md §4.6).
- `system_ext_a` is EROFS with no free space inside the partition. The group `google_system_dynamic_partitions_a` has a maximum size of 6.8 GB and holds 1.46 GB, so the partition can grow in the super metadata.
- The policy is split: `system_ext` carries `system_ext_sepolicy.cil`, `system_ext_seapp_contexts`, and `system_ext_file_contexts`, and `odm_a` carries `precompiled_sepolicy` with the SHA-256s of its inputs. The stock top-level `vbmeta_a` authenticates the `odm` hashtree directly; `vbmeta_system_a` authenticates `system_ext`.

`Images/tools` already rebuilds EROFS partitions, reseals hashtrees, replaces super partitions, and re-signs vbmeta for #99 (android-image.md §4.6), and `Experiments/sepolicy-022/` edited the ODM policy of a bundle that then booted.

The stock build is never published (legal-and-licensing.md §2), so a development image derived from it is never published either.

## Decision

1. **Development custom images are composed, not built.** `python3 -m apkrun_image compose` takes the pinned stock Cuttlefish build and adds the APKRun product files. It runs on the developer Mac, like the rest of `Images/tools`. The output is a `kind: apkrun` bundle used for development and for the AndroidCustom suite. It is never published.
2. **`Guest/product/` stays the one source** of what the product adds: the priv-app APKs, `apkrun_vsockd`, `init/apkrun.rc`, `permissions/`, the SELinux policy, and the settings. The composer reads a placement list in `Guest/product/` that gives each file its path, mode, owner, and label. It does not read `Android.bp` or makefiles.
3. **Placement.** Added files go into `system_ext_a`, the partition that a product build would use for them. The composer grows `system_ext_a` in its super group when needed and may grow `odm_a` within its existing group when the compiled policy and sidecars require more room. It changes no other partition. It rebuilds the `system_ext` and `odm` hashtrees and FEC with the pinned avbtool, updates their respective descriptors in `vbmeta_system_a` and `vbmeta_a`, re-signs both with the AOSP AVB test key, and recomputes the vbmeta digest in bootconfig.
4. **Platform signature.** The agents are signed with the public AOSP test platform key, pinned as a test key under `Tests/Fixtures/signing/`. This signature, and every privilege that comes from it, holds only on composed images.
5. **SELinux.** The policy is written as CIL fragments, because the image's split policy is CIL. The composer adds the fragments to `system_ext_sepolicy.cil`, adds the `seapp_contexts` and `file_contexts` entries, and compiles a new `precompiled_sepolicy` on the host with a pinned `secilc` from the same inputs that `init` would use. `secilc` checks the `neverallow` rules. The new domains are permissive, as in a `userdebug` product build (guest-components.md §4.2).
6. **Release images are a separate task (#120).** A published image needs APKRun's own platform and release keys and a `user` variant, and it must not contain the prebuilt stock build. #120 chooses between the AOSP product build of android-image.md §11.6 and re-signing the CI target files, settles OQ-36, and owns R-14. Until then, no APKRun image is published.

## Alternatives considered

| Alternative | Why not now |
|---|---|
| AOSP product build on a Linux builder (the plan of #36) | No builder exists, a build takes hours, and every M5–M9 task would wait for it. It stays an option for #120 |
| CI target files and AOSP `releasetools` (`sign_target_files_apks`, `add_img_to_target_files`) on Linux | It needs Linux x86-64 tools that do not run on this Mac. It fits the release keys, so #120 considers it |
| Install the agents with `adb install` into `/data` on the stock image | Not a priv-app: no privileged permissions, no `persistent`, ADB stays required. It is the development mode that exists already |
| Let `init` compile the policy on the device | It works when the hashes in `odm_a` stop matching, but it adds boot time and finds `neverallow` violations only at boot |

## Consequences

- #36 can start on this Mac. #37 and the tasks after it run on the composed image.
- The public test platform key means any APK signed with it has platform privileges on a composed image. Composed images are therefore development-only, and the release checks refuse them (runtime-image-manifest.md §7.3).
- The composed image can differ from a later product build: Soong's build-time checks and generated files are missing. #120 runs the AndroidCustom suite again on its image.
- The bundle `provenance` of `kind: apkrun` records the composition (the stock build and the input SHA-256s) instead of a builder manifest and container digest. #36 changes S1, S2, and S13 of runtime-image-manifest.md §7.2 and the schema.
- A change of the stock build pin changes the composed image. The composer refuses an input whose layout differs from what it expects.

## Verification

- #36: the composed image reaches `boot_completed` with the enforcing policy. `dumpsys package io.apkrun.guest` shows the platform signature and every permission granted, and the agents answer over vsock with ADB off.
- #120: the release image passes the same suite without the test keys.
