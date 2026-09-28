# 0011. Prebuilt runtime image bundle

- Status: Accepted
- Date: 2026-09-28
- Related: #008–#010, #065, #057–#058, #087, [../../02-design/android-image.md](../../02-design/android-image.md)

## Context

Android images come as AOSP build outputs: a zip with boot images, sparse partition images, and vbmeta. Booting them under VZ needs a decompressed kernel, a combined initrd with a bootconfig trailer, raw (unsparsed) disks, a GPT composite layout, and a cmdline. Doing all this on every user's Mac at runtime would add complexity, time, and failure modes.

## Decision

A build-time pipeline (Python under `Images/tools/`) turns an AOSP build into a **runtime image bundle**. The bundle holds the kernel (uncompressed `Image`), `ramdisk.img` (vendor ramdisks + generic ramdisk, concatenated), `bootconfig.txt` (the vendor and image bootconfig layers), `cmdline.txt`, raw GPT disk images (the read-only OS disk, and templates for the writable disks), a `manifest.json` (versions, disk roles, sizes, required agents, protocol versions, hashes), and `SHA256SUMS`. `manifest.sig` signs the manifest, and the manifest holds the hash of every file ([../../03-reference/runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md) §3.1, §6). The Mac runtime (`ImageCore`) only verifies, installs, and consumes bundles. It never parses AOSP build outputs. The only boot artifact it writes is the per-boot initrd: `ramdisk.img` plus one bootconfig trailer merged from the bundle's layers and the host's platform and instance layers ([../../02-design/android-image.md](../../02-design/android-image.md) §6.3).

For M1 development the same pipeline runs locally on the developer's Mac against the stock Cuttlefish image zip.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Parse the AOSP zip at runtime | Slow first run, and heavy code (sparse, LZ4, boot image formats) in the product |
| Ship the image inside APKRun.app | Several GB in the app bundle, and ties image updates to app updates |

## Consequences

- There is one well-defined artifact format with its own versioning ([../../03-reference/runtime-image-manifest.md](../../03-reference/runtime-image-manifest.md)).
- Image distribution (#087) needs hosting, signatures, and resumable downloads.

## Verification

#065 acceptance: the bundle from the stock image boots to `sys.boot_completed=1` under VZ.
