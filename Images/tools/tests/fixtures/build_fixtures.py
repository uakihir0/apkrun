#!/usr/bin/env python3
"""Build deterministic synthetic Android image fixtures with pinned AOSP tools."""

from __future__ import annotations

import argparse
import hashlib
import struct
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path
from tempfile import TemporaryDirectory

FIXTURE_ROOT = Path(__file__).resolve().parent
REPOSITORY_ROOT = FIXTURE_ROOT.parents[3]
DEFAULT_OUTPUT = FIXTURE_ROOT / "images"
MKBOOTIMG = REPOSITORY_ROOT / "Images/tools/vendor/mkbootimg/mkbootimg.py"
AVBTOOL = REPOSITORY_ROOT / "Images/tools/vendor/avb/avbtool.py"
SIGNING_KEY = REPOSITORY_ROOT / "Tests/Fixtures/signing/test-apkrun-image-fixture-rsa.pem"
SIGNING_PUBLIC_KEY = REPOSITORY_ROOT / "Tests/Fixtures/signing/test-apkrun-image-fixture.avbpubkey"
ZIP_NAME = "aosp_cf_arm64_only_phone-img-fixture.zip"
BLOCK_SIZE = 4096
SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4


def run_tool(arguments: list[str]) -> None:
    """Run a pinned image utility without invoking a shell."""
    subprocess.run(arguments, check=True)


def build_boot_images(work_directory: Path, output_directory: Path) -> None:
    """Use the pinned AOSP mkbootimg utility for boot and vendor_boot images."""
    kernel = work_directory / "kernel"
    kernel_bytes = bytearray(4096)
    kernel_bytes[0x38:0x3C] = b"ARM\x64"
    kernel.write_bytes(kernel_bytes)

    ramdisk = work_directory / "ramdisk.img"
    ramdisk.write_bytes(b"APKRun synthetic generic ramdisk\n")
    run_tool(
        [
            sys.executable,
            str(MKBOOTIMG),
            "--header_version",
            "4",
            "--pagesize",
            str(BLOCK_SIZE),
            "--kernel",
            str(kernel),
            "--ramdisk",
            str(ramdisk),
            "--os_version",
            "17.0.0",
            "--os_patch_level",
            "2026-09",
            "--cmdline",
            "console=hvc0 panic=-1",
            "--output",
            str(output_directory / "boot.img"),
        ]
    )
    run_tool(
        [
            sys.executable,
            str(MKBOOTIMG),
            "--header_version",
            "4",
            "--pagesize",
            str(BLOCK_SIZE),
            "--ramdisk",
            str(ramdisk),
            "--os_version",
            "17.0.0",
            "--os_patch_level",
            "2026-09",
            "--output",
            str(output_directory / "init_boot.img"),
        ]
    )

    platform_ramdisk = work_directory / "platform.cpio"
    recovery_ramdisk = work_directory / "recovery.cpio"
    dlkm_ramdisk = work_directory / "dlkm.cpio"
    platform_ramdisk.write_bytes(b"platform fragment\n")
    recovery_ramdisk.write_bytes(b"recovery fragment\n")
    dlkm_ramdisk.write_bytes(b"dlkm fragment\n")
    bootconfig = work_directory / "vendor-bootconfig.txt"
    bootconfig.write_text("androidboot.hardware=cutf_cvm\n", encoding="ascii")
    vendor_arguments = [
        sys.executable,
        str(MKBOOTIMG),
        "--header_version",
        "4",
        "--pagesize",
        str(BLOCK_SIZE),
        "--vendor_boot",
        str(output_directory / "vendor_boot.img"),
        "--vendor_cmdline",
        "console=hvc0 panic=-1",
        "--vendor_bootconfig",
        str(bootconfig),
    ]
    for ramdisk_type, ramdisk_name, path in (
        ("platform", "platform", platform_ramdisk),
        ("recovery", "recovery", recovery_ramdisk),
        ("dlkm", "dlkm", dlkm_ramdisk),
    ):
        vendor_arguments.extend(
            [
                "--ramdisk_type",
                ramdisk_type,
                "--ramdisk_name",
                ramdisk_name,
                "--vendor_ramdisk_fragment",
                str(path),
            ]
        )
    run_tool(vendor_arguments)


def build_vbmeta(work_directory: Path, output_directory: Path) -> None:
    """Build a vbmeta image carrying two chain-partition descriptors."""
    extracted_public_key = work_directory / "fixture.avbpubkey"
    run_tool(
        [
            sys.executable,
            str(AVBTOOL),
            "extract_public_key",
            "--key",
            str(SIGNING_KEY),
            "--output",
            str(extracted_public_key),
        ]
    )
    if extracted_public_key.read_bytes() != SIGNING_PUBLIC_KEY.read_bytes():
        raise ValueError("fixture RSA private key does not match its pinned AVB public key")
    run_tool(
        [
            sys.executable,
            str(AVBTOOL),
            "make_vbmeta_image",
            "--output",
            str(output_directory / "vbmeta.img"),
            "--algorithm",
            "NONE",
            "--rollback_index",
            "7",
            "--chain_partition",
            f"system_a:1:{SIGNING_PUBLIC_KEY}",
            "--chain_partition",
            f"vendor_a:2:{SIGNING_PUBLIC_KEY}",
        ]
    )


def filesystem_images() -> dict[str, bytes]:
    """Create small ext4, EROFS, and F2FS superblock fixtures."""
    ext4 = bytearray(BLOCK_SIZE * 8)
    struct.pack_into("<I", ext4, 1024 + 4, 8)
    struct.pack_into("<I", ext4, 1024 + 24, 2)
    struct.pack_into("<H", ext4, 1024 + 56, 0xEF53)

    erofs = bytearray(BLOCK_SIZE)
    struct.pack_into("<I", erofs, 1024, 0xE0F5E1E2)
    erofs[1024 + 12] = 12
    struct.pack_into("<I", erofs, 1024 + 36, 1)

    f2fs = bytearray(BLOCK_SIZE)
    struct.pack_into("<I", f2fs, 1024, 0xF2F52010)
    struct.pack_into("<I", f2fs, 1024 + 16, 12)
    struct.pack_into("<Q", f2fs, 1024 + 36, 1)

    return {
        "ext4.img": bytes(ext4),
        "erofs.img": bytes(erofs),
        "f2fs.img": bytes(f2fs),
    }


def build_sparse_image(expanded_blocks: list[bytes], *, include_all_chunks: bool) -> bytes:
    """Build a checksummed sparse image with selected chunk types."""
    if any(len(block) != BLOCK_SIZE for block in expanded_blocks):
        raise ValueError("each sparse fixture block must be exactly 4096 bytes")
    expanded = b"".join(expanded_blocks)
    chunks: list[bytes] = []
    if include_all_chunks:
        chunks.extend(
            [
                struct.pack("<HHII", CHUNK_RAW, 0, 1, 12 + BLOCK_SIZE) + expanded_blocks[0],
                struct.pack("<HHII", CHUNK_FILL, 0, 1, 16) + b"FILL",
                struct.pack(
                    "<HHII",
                    CHUNK_DONT_CARE,
                    0,
                    len(expanded_blocks) - 2,
                    12,
                ),
                struct.pack("<HHII", CHUNK_CRC32, 0, 0, 16)
                + struct.pack("<I", zlib.crc32(expanded)),
            ]
        )
    else:
        chunks.append(
            struct.pack(
                "<HHII",
                CHUNK_RAW,
                0,
                len(expanded_blocks),
                12 + len(expanded),
            )
            + expanded
        )
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        BLOCK_SIZE,
        len(expanded_blocks),
        len(chunks),
        zlib.crc32(expanded),
    )
    return header + b"".join(chunks)


def build_liblp_super() -> bytes:
    """Build a minimal checksummed liblp super image with two named partitions."""
    geometry = bytearray(BLOCK_SIZE)
    struct.pack_into("<II", geometry, 0, 0x616C4467, 52)
    struct.pack_into("<III", geometry, 40, BLOCK_SIZE, 2, BLOCK_SIZE)
    geometry[8:40] = hashlib.sha256(geometry[:52]).digest()

    partition_table = struct.pack("<36sIIII", b"system_a", 0, 0, 1, 0) + struct.pack(
        "<36sIIII", b"vendor_a", 0, 1, 1, 0
    )
    extent_table = struct.pack("<QIQI", 2048, 0, 0, 0) + struct.pack(
        "<QIQI",
        1024,
        0,
        2048,
        0,
    )
    group_table = struct.pack("<36sIQ", b"google_dynamic_partitions_a", 0, 0)
    device_table = struct.pack(
        "<QIIQ36sI",
        0,
        0,
        0,
        2 * 1024 * 1024,
        b"super",
        0,
    )
    tables = partition_table + extent_table + group_table + device_table

    header = bytearray(128)
    struct.pack_into("<IHHI", header, 0, 0x414C5030, 10, 2, 128)
    struct.pack_into("<I", header, 44, len(tables))
    header[48:80] = hashlib.sha256(tables).digest()
    descriptors = (
        (0, 2, 52),
        (len(partition_table), 2, 24),
        (len(partition_table) + len(extent_table), 1, 48),
        (len(partition_table) + len(extent_table) + len(group_table), 1, 64),
    )
    for index, descriptor in enumerate(descriptors):
        struct.pack_into("<III", header, 80 + index * 12, *descriptor)
    header[12:44] = hashlib.sha256(header).digest()

    metadata_start = BLOCK_SIZE * 3
    image = bytearray(2 * 1024 * 1024)
    image[BLOCK_SIZE : BLOCK_SIZE * 2] = geometry
    image[BLOCK_SIZE * 2 : BLOCK_SIZE * 3] = geometry
    metadata = bytes(header) + tables
    image[metadata_start : metadata_start + len(metadata)] = metadata
    return bytes(image)


def write_zip(output_directory: Path, image_paths: list[Path]) -> Path:
    """Write the fixture archive with stable metadata and entry order."""
    archive_path = output_directory / ZIP_NAME
    with zipfile.ZipFile(archive_path, "w") as archive:
        for path in sorted(image_paths, key=lambda item: item.name.encode("utf-8")):
            info = zipfile.ZipInfo(path.name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = (0o100644 & 0xFFFF) << 16
            archive.writestr(info, path.read_bytes())
    return archive_path


def write_checksums(output_directory: Path, paths: list[Path]) -> None:
    """Write sorted SHA-256 records for every generated fixture."""
    lines = [
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}"
        for path in sorted(paths, key=lambda item: item.name.encode("utf-8"))
    ]
    (output_directory / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="ascii")


def build(output_directory: Path) -> None:
    """Generate all documented synthetic fixtures."""
    if not MKBOOTIMG.is_file() or not AVBTOOL.is_file():
        raise FileNotFoundError(
            "pinned image tools are missing; run the repository bootstrap first"
        )
    for signing_material in (SIGNING_KEY, SIGNING_PUBLIC_KEY):
        if not signing_material.is_file():
            raise FileNotFoundError(f"fixture signing material is missing: {signing_material}")
    output_directory.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix="apkrun-image-fixtures-") as work_path:
        work_directory = Path(work_path)
        build_boot_images(work_directory, output_directory)
        build_vbmeta(work_directory, output_directory)

    generated: dict[str, bytes] = filesystem_images()
    sparse_blocks = [
        generated["ext4.img"][:BLOCK_SIZE],
        b"FILL" * (BLOCK_SIZE // 4),
        *[bytes(BLOCK_SIZE) for _ in range(6)],
    ]
    generated["sparse-all-chunks.img"] = build_sparse_image(
        sparse_blocks,
        include_all_chunks=True,
    )
    super_image = build_liblp_super()
    generated["super.img"] = build_sparse_image(
        [
            super_image[offset : offset + BLOCK_SIZE]
            for offset in range(0, len(super_image), BLOCK_SIZE)
        ],
        include_all_chunks=False,
    )
    generated["userdata.img"] = build_sparse_image(
        [
            generated["ext4.img"][offset : offset + BLOCK_SIZE]
            for offset in range(0, len(generated["ext4.img"]), BLOCK_SIZE)
        ],
        include_all_chunks=False,
    )
    generated["android-info.txt"] = b"config=phone\ngfxstream=supported\n"
    generated["fastboot-info.txt"] = b"flash boot boot.img\nreboot\n"
    generated["unknown.bin"] = b"\0synthetic unknown input\n"
    for name, content in generated.items():
        (output_directory / name).write_bytes(content)
    image_paths = sorted(
        (
            output_directory / name
            for name in (
                "boot.img",
                "init_boot.img",
                "vendor_boot.img",
                "vbmeta.img",
                *generated,
            )
        ),
        key=lambda item: item.name.encode("utf-8"),
    )
    archive_path = write_zip(output_directory, image_paths)
    write_checksums(output_directory, [*image_paths, archive_path])


def main(argv: list[str] | None = None) -> int:
    """Command-line entry point."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args(argv)
    build(arguments.out.expanduser())
    return 0


if __name__ == "__main__":
    sys.exit(main())
