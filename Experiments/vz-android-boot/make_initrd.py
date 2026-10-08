"""Build the per-boot initrd (ramdisk + bootconfig trailer) for the VZ boot spike.

Experiment only. The production path is `BootconfigWriter` and
`AndroidBootPlanner` (#012). The layers follow android-image.md §6.1:
vendor (from vendor_boot), image (slot, AVB, and the Cuttlefish launcher's
values from a #064 capture), platform (`boot_devices`), and instance.

Usage:
    python3 -I make_initrd.py --repo <repo root> --capture <internal-bootconfig.txt> \
        --boot-devices 40000000.pci --gpu none --memory-mib 4096 --out <dir>
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import json
import sys
import zipfile
from collections.abc import Iterator, Mapping
from pathlib import Path
from typing import Any, BinaryIO

# Keys of the launcher's bootconfig that configure host services APKRun does
# not run (android-image.md §6.2, §7.3), or that a later layer sets. The lights,
# audio control, and OpenThread keys stay: they configure guest-side servers,
# and their HALs abort without them (first VZ spike run).
DROPPED_PREFIXES = (
    "androidboot.vsock_tombstone_port",
    "androidboot.vhal_proxy_server_port",
    "androidboot.auto_eth_guest_addr",
    "androidboot.boot_devices",
    "androidboot.serialno",
    "androidboot.ddr_size",
    "androidboot.serialconsole",
    "androidboot.console",
)

# Graphics keys that Cuttlefish's launcher writes only when a GPU is attached;
# the gpu_mode=none capture has none of them.
GRAPHICS_PREFIXES = (
    "androidboot.cpuvulkan.version",
    "androidboot.hardware.angle_feature_overrides_",
    "androidboot.hardware.egl",
    "androidboot.hardware.gralloc",
    "androidboot.hardware.hwcomposer",
    "androidboot.hardware.vulkan",
    "androidboot.opengles.version",
)


def parse_lines(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"')
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--capture", required=True, type=Path)
    parser.add_argument("--boot-devices", required=True)
    parser.add_argument("--gpu", choices=["none", "swiftshader"], default="none")
    parser.add_argument("--memory-mib", type=int, default=4096)
    parser.add_argument("--serialno", default="APKRUNSPIKE0")
    parser.add_argument("--extra", action="append", default=[], help="key=value, image layer")
    parser.add_argument("--drop", action="append", default=[], help="key to remove")
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    sys.path.insert(0, str(args.repo / "Images" / "tools"))
    from apkrun_image import avb, bootconfig  # noqa: PLC0415

    work = args.repo / "Images" / "work" / "16373615"
    manifest_path = args.repo / "Images" / "manifests" / "16373615" / "android-image.json"
    document = json.loads(manifest_path.read_text())
    archive_path = work / "download" / "aosp_cf_arm64_only_phone-img-16373615.zip"

    with zipfile.ZipFile(archive_path) as archive:

        @contextlib.contextmanager
        def open_artifact(artifact: Mapping[str, Any]) -> Iterator[BinaryIO]:
            data = archive.read(artifact["file"])
            if hashlib.sha256(data).hexdigest() != artifact["sha256"]:
                raise SystemExit(f"{artifact['file']}: SHA-256 mismatch")
            yield io.BytesIO(data)

        vbmeta_values = avb.calculate_vbmeta_bootconfig(document, open_artifact)

    vendor = parse_lines((work / "boot" / "vendor-bootconfig.txt").read_text())
    launcher = parse_lines(args.capture.read_text())
    image: dict[str, str] = {}
    for key, value in launcher.items():
        if key.startswith(DROPPED_PREFIXES):
            continue
        if args.gpu == "none" and key.startswith(GRAPHICS_PREFIXES):
            continue
        image[key] = value
    image.update(
        {
            "androidboot.slot_suffix": "_a",
            "androidboot.force_normal_boot": "1",
            "androidboot.verifiedbootstate": "orange",
            "androidboot.vbmeta.device_state": "unlocked",
            "androidboot.hypervisor.vm.supported": "0",
            "androidboot.console": "hvc1",
            "androidboot.serialconsole": "1",
        }
    )
    image.update(vbmeta_values)
    for item in args.extra:
        key, _, value = item.partition("=")
        image[key] = value
    for key in args.drop:
        image.pop(key, None)

    layers = [
        bootconfig.BootconfigLayer("vendor", vendor),
        bootconfig.BootconfigLayer("image", image),
        bootconfig.BootconfigLayer("platform", {"androidboot.boot_devices": args.boot_devices}),
        bootconfig.BootconfigLayer(
            "instance",
            {
                "androidboot.serialno": args.serialno,
                "androidboot.ddr_size": f"{args.memory_mib}MB",
            },
        ),
    ]
    merged = bootconfig.merge_bootconfig_layers(layers)
    text = bootconfig.serialize_bootconfig(merged)
    command_line = (work / "boot" / "cmdline.txt").read_text().strip()
    trailer = bootconfig.make_bootconfig_trailer(text, command_line=command_line)

    args.out.mkdir(parents=True, exist_ok=True)
    ramdisk = (work / "boot" / "ramdisk.img").read_bytes()
    (args.out / "initrd.img").write_bytes(ramdisk + trailer)
    (args.out / "bootconfig.txt").write_bytes(text)
    (args.out / "cmdline.txt").write_text(command_line + "\n")
    print(f"bootconfig: {len(text)} bytes, {len(merged)} keys")
    print(f"sha256: {hashlib.sha256(text).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
