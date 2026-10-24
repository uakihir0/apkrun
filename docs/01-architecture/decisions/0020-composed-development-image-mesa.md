# 0020. Compose guest Mesa into the development image

- Status: Accepted
- Date: 2026-10-24
- Approval: the project owner authorized completing #36 and its documented acceptance checks in this session.
- Related: #36, #99, ADR-0004, ADR-0018, ADR-0019, [android-image.md](../../02-design/android-image.md) §11, [graphics.md](../../02-design/graphics.md) §5.3, §9.1

## Context

ADR-0019 made the development image from the pinned Cuttlefish image by composing APKRun's product files into `system_ext_a` and compiling its SELinux policy into `odm_a`. The product image also selects Mesa with `androidboot.hardware.egl=mesa`, but the stock `vendor_a` contains only the emulation EGL/GLES libraries. Leaving `vendor_a` unchanged makes SurfaceFlinger abort while it loads the selected EGL driver.

Task #36 requires the composed image to render through Mesa VirGL and run HelloGL as an untrusted app. The pinned Mesa libraries are already built and staged by #99, and the vendor rebuild checks that all stock EROFS entries, metadata, contents, and labels remain unchanged.

## Decision

1. The #36 composer requires the verified output staged at `Guest/product/mesa/prebuilt/`. It snapshots and hashes the Mesa manifest and four AArch64 shared libraries along with the other product inputs.
2. The composer reuses the vendor EROFS rebuild checks to add only the four Mesa libraries under `/vendor/lib64/egl/`. It keeps the `vendor_a` dynamic partition size and the stock AVB hashtree parameters, including FEC.
3. The composed `super.img` contains the rebuilt `vendor_a`, `system_ext_a`, and `odm_a`. The composer updates `vbmeta_a` from the stock image for `odm`, then updates that signed image for `vendor`, validating that both descriptors match their rebuilt partitions.
4. The other accepted decisions of ADR-0019 remain: development images use the pinned stock build, the APKRun product tree remains the source of product inputs, and composed images use development test keys and are never published.

## Alternatives considered

| Alternative | Why not |
|---|---|
| Leave Mesa injection as a separate operator step | It can leave the bundle with a `mesa` boot property and no matching guest libraries, as the failed SurfaceFlinger boot demonstrated |
| Use the #99 no-FEC reseal output directly | #36 has the pinned FEC utility and must preserve the stock vendor hashtree parameters |
| Build a full AOSP product image for development | It needs the Linux AOSP builder that ADR-0019 avoids and would delay the AndroidCustom suite |

## Consequences

- The #36 composition requires a verified staged Mesa build in addition to its other product inputs.
- `composition.json` records the Mesa manifest and library hashes, source metadata, injected destinations and labels, and resulting vendor descriptor.
- The existing runtime-manifest `composition.productInputs` list records Mesa input hashes without changing its schema.
- The vendor partition contents differ only by the four Mesa libraries and their containing directory metadata; its dynamic partition size and other super extents remain unchanged.

## Verification

- Composer unit tests verify Mesa input validation, provenance, vendor insertion, AVB descriptor updates, FEC preservation, and deterministic outputs.
- AndroidCustom and G3 verify enforcing boot, Mesa EGL selection, SurfaceFlinger VirGL, and HelloGL rendering in `u:r:untrusted_app`.
