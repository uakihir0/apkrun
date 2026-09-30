"""Boot image parsing tests compared with the vendored AOSP unpacker."""

from __future__ import annotations

import io
import struct
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Literal
from zipfile import ZipFile

import pytest

from apkrun_image.bootimg import (
    BootImageError,
    RamdiskType,
    parse_boot_image,
    parse_vendor_boot_image,
    read_section,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_DIRECTORY = Path(__file__).resolve().parent / "fixtures/images"
UNPACK_BOOTIMG = REPOSITORY_ROOT / "Images/tools/vendor/mkbootimg/unpack_bootimg.py"
PINNED_ARCHIVE = (
    REPOSITORY_ROOT / "Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip"
)


@pytest.mark.parametrize(
    ("filename", "kind", "expected_cmdline"),
    (
        ("boot.img", "boot", "console=hvc0 panic=-1"),
        ("init_boot.img", "init_boot", ""),
    ),
)
def test_boot_v4_sections_match_vendored_aosp_unpacker(
    filename: str,
    kind: Literal["boot", "init_boot"],
    expected_cmdline: str,
    tmp_path: Path,
) -> None:
    """Boot and init_boot payload offsets agree byte-for-byte with AOSP tooling."""
    image_path = FIXTURE_DIRECTORY / filename
    image_size = image_path.stat().st_size
    output_directory = tmp_path / "unpacked"
    subprocess.run(
        [
            sys.executable,
            str(UNPACK_BOOTIMG),
            "--boot_img",
            str(image_path),
            "--out",
            str(output_directory),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )

    original_bytes = image_path.read_bytes()
    with image_path.open("rb") as stream:
        header = parse_boot_image(stream, image_size, kind=kind)
        assert (
            read_section(stream, image_size, header.kernel, "kernel")
            == (output_directory / "kernel").read_bytes()
        )
        assert (
            read_section(stream, image_size, header.ramdisk, "ramdisk")
            == (output_directory / "ramdisk").read_bytes()
        )

    assert header.header_version == 4
    assert header.header_size == 1584
    assert header.page_size == 4096
    assert header.cmdline == expected_cmdline
    assert header.os_version == struct.unpack_from("<I", original_bytes, 16)[0]
    assert image_path.read_bytes() == original_bytes


def test_vendor_boot_v4_sections_and_fragments_match_vendored_aosp_unpacker(
    tmp_path: Path,
) -> None:
    """Vendor ramdisk fragments, DTB, and bootconfig match AOSP extraction."""
    image_path = FIXTURE_DIRECTORY / "vendor_boot.img"
    image_size = image_path.stat().st_size
    output_directory = tmp_path / "unpacked"
    subprocess.run(
        [
            sys.executable,
            str(UNPACK_BOOTIMG),
            "--boot_img",
            str(image_path),
            "--out",
            str(output_directory),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )

    original_bytes = image_path.read_bytes()
    with image_path.open("rb") as stream:
        header = parse_vendor_boot_image(stream, image_size)
        assert read_section(stream, image_size, header.dtb, "DTB") == b""
        assert (
            read_section(stream, image_size, header.bootconfig, "bootconfig")
            == (output_directory / "bootconfig").read_bytes()
        )
        for index, fragment in enumerate(header.fragments):
            expected = output_directory / f"vendor_ramdisk{index:02}"
            assert read_section(stream, image_size, fragment.section, fragment.name) == (
                expected.read_bytes()
            )

    assert header.header_version == 4
    assert header.header_size == 2128
    assert header.page_size == 4096
    assert header.cmdline == "console=hvc0 panic=-1"
    assert [fragment.kind for fragment in header.fragments] == [
        RamdiskType.PLATFORM,
        RamdiskType.RECOVERY,
        RamdiskType.DLKM,
    ]
    assert [fragment.name for fragment in header.fragments] == [
        "platform",
        "recovery",
        "dlkm",
    ]
    assert image_path.read_bytes() == original_bytes


def test_vendor_boot_nonempty_dtb_matches_vendored_aosp_unpacker(tmp_path: Path) -> None:
    """A non-empty DTB shifts and preserves the ramdisk table and bootconfig."""
    original = (FIXTURE_DIRECTORY / "vendor_boot.img").read_bytes()
    page_size = struct.unpack_from("<I", original, 12)[0]
    vendor_ramdisk_size = struct.unpack_from("<I", original, 24)[0]
    header_size = struct.unpack_from("<I", original, 2096)[0]
    old_dtb_size = struct.unpack_from("<I", original, 2100)[0]
    table_size = struct.unpack_from("<I", original, 2112)[0]
    dtb_start = (header_size + page_size - 1) // page_size * page_size + (
        vendor_ramdisk_size + page_size - 1
    ) // page_size * page_size
    old_table_start = (dtb_start + old_dtb_size + page_size - 1) // page_size * page_size
    dtb_bytes = b"non-empty synthetic dtb"
    padded_dtb = dtb_bytes.ljust(
        (len(dtb_bytes) + page_size - 1) // page_size * page_size,
        b"\x00",
    )
    image = bytearray(original[:dtb_start] + padded_dtb + original[old_table_start:])
    struct.pack_into("<I", image, 2100, len(dtb_bytes))

    image_path = tmp_path / "vendor_boot-with-dtb.img"
    image_path.write_bytes(image)
    output_directory = tmp_path / "unpacked"
    subprocess.run(
        [
            sys.executable,
            str(UNPACK_BOOTIMG),
            "--boot_img",
            str(image_path),
            "--out",
            str(output_directory),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )

    with image_path.open("rb") as stream:
        header = parse_vendor_boot_image(stream, len(image))
        assert (
            read_section(stream, len(image), header.dtb, "DTB")
            == (output_directory / "dtb").read_bytes()
        )
        assert (
            read_section(stream, len(image), header.bootconfig, "bootconfig")
            == (output_directory / "bootconfig").read_bytes()
        )
        for index, fragment in enumerate(header.fragments):
            assert (
                read_section(stream, len(image), fragment.section, fragment.name)
                == (output_directory / f"vendor_ramdisk{index:02}").read_bytes()
            )

    assert table_size == struct.unpack_from("<I", image, 2112)[0]
    assert header.dtb.size == len(dtb_bytes)
    assert (output_directory / "dtb").read_bytes() == dtb_bytes


def test_vendor_boot_utf8_fragment_name_matches_vendored_aosp_unpacker(
    tmp_path: Path,
) -> None:
    """UTF-8 table names use the same decoding as the vendored AOSP tools."""
    image = bytearray((FIXTURE_DIRECTORY / "vendor_boot.img").read_bytes())
    page_size = struct.unpack_from("<I", image, 12)[0]
    ramdisk_size = struct.unpack_from("<I", image, 24)[0]
    dtb_size = struct.unpack_from("<I", image, 2100)[0]
    header_size = struct.unpack_from("<I", image, 2096)[0]
    table_offset = (
        (header_size + page_size - 1) // page_size * page_size
        + (ramdisk_size + page_size - 1) // page_size * page_size
        + (dtb_size + page_size - 1) // page_size * page_size
    )
    name = "plátform"
    encoded_name = name.encode("utf-8")
    image[table_offset + 12 : table_offset + 44] = encoded_name.ljust(32, b"\x00")
    image_path = tmp_path / "vendor_boot-utf8-name.img"
    image_path.write_bytes(image)
    output_directory = tmp_path / "unpacked"
    subprocess.run(
        [
            sys.executable,
            str(UNPACK_BOOTIMG),
            "--boot_img",
            str(image_path),
            "--out",
            str(output_directory),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )

    with image_path.open("rb") as stream:
        header = parse_vendor_boot_image(stream, len(image))

    assert header.fragments[0].name == name
    assert (output_directory / "vendor-ramdisk-by-name" / f"ramdisk_{name}").is_symlink()


@pytest.mark.parametrize(
    ("filename", "kind", "cmdline_offset", "cmdline_size"),
    (
        ("boot.img", "boot", 44, 1536),
        ("vendor_boot.img", "vendor_boot", 28, 2048),
    ),
)
def test_boot_command_lines_decode_utf8_like_vendored_aosp(
    filename: str,
    kind: Literal["boot", "vendor_boot"],
    cmdline_offset: int,
    cmdline_size: int,
    tmp_path: Path,
) -> None:
    """Both boot v4 command-line fields preserve AOSP-accepted UTF-8."""
    image = bytearray((FIXTURE_DIRECTORY / filename).read_bytes())
    expected_cmdline = "console=hvc0 café"
    encoded_cmdline = expected_cmdline.encode("utf-8")
    image[cmdline_offset : cmdline_offset + cmdline_size] = encoded_cmdline.ljust(
        cmdline_size,
        b"\x00",
    )
    image_path = tmp_path / filename
    image_path.write_bytes(image)
    output_directory = tmp_path / "unpacked"
    oracle = subprocess.run(
        [
            sys.executable,
            str(UNPACK_BOOTIMG),
            "--boot_img",
            str(image_path),
            "--out",
            str(output_directory),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    oracle_label = "command line args:" if kind == "boot" else "vendor command line args:"
    assert f"{oracle_label} {expected_cmdline}" in oracle.stdout

    with image_path.open("rb") as stream:
        if kind == "boot":
            parsed_cmdline = parse_boot_image(stream, len(image), kind="boot").cmdline
        else:
            parsed_cmdline = parse_vendor_boot_image(stream, len(image)).cmdline

    assert parsed_cmdline == expected_cmdline


def test_pinned_boot_images_parse_from_the_real_archive() -> None:
    """The v4 parsers accept the selected Cuttlefish build without extracting it."""
    if not PINNED_ARCHIVE.is_file():
        pytest.skip("pinned Cuttlefish archive is not downloaded")

    with ZipFile(PINNED_ARCHIVE) as archive:
        boot_size = archive.getinfo("boot.img").file_size
        with archive.open("boot.img") as stream:
            boot = parse_boot_image(stream, boot_size, kind="boot")
        init_boot_size = archive.getinfo("init_boot.img").file_size
        with archive.open("init_boot.img") as stream:
            init_boot = parse_boot_image(stream, init_boot_size, kind="init_boot")
        vendor_boot_size = archive.getinfo("vendor_boot.img").file_size
        with archive.open("vendor_boot.img") as stream:
            vendor_boot = parse_vendor_boot_image(stream, vendor_boot_size)

    assert boot.kernel.size > 0
    assert init_boot.kernel.size == 0
    assert init_boot.ramdisk.size > 0
    assert vendor_boot.fragments
    assert vendor_boot.bootconfig.size > 0


def test_vendor_boot_parser_accepts_none_fragment_type() -> None:
    """The standard NONE table type is retained as a parsed enum value."""
    image_path = FIXTURE_DIRECTORY / "vendor_boot.img"
    image = bytearray(image_path.read_bytes())
    page_size = struct.unpack_from("<I", image, 12)[0]
    ramdisk_size = struct.unpack_from("<I", image, 24)[0]
    dtb_size = struct.unpack_from("<I", image, 2100)[0]
    table_offset = (
        (struct.unpack_from("<I", image, 2096)[0] + page_size - 1) // page_size * page_size
        + (ramdisk_size + page_size - 1) // page_size * page_size
        + (dtb_size + page_size - 1) // page_size * page_size
    )
    struct.pack_into("<I", image, table_offset + 8, RamdiskType.NONE)

    header = parse_vendor_boot_image(io.BytesIO(image), len(image))

    assert header.fragments[0].kind is RamdiskType.NONE


@pytest.mark.parametrize(
    ("mutator", "message"),
    (
        (lambda image: image.__setitem__(slice(0, 8), b"NOTBOOT!"), "invalid magic"),
        (lambda image: struct.pack_into("<I", image, 40, 3), "version 3 is not v4"),
        (lambda image: struct.pack_into("<I", image, 20, 0), "header size 0 is not 1584"),
    ),
)
def test_boot_parser_rejects_invalid_headers(
    mutator: Callable[[bytearray], None],
    message: str,
) -> None:
    """Wrong magic, header version, and header size fail with typed diagnostics."""
    image = bytearray((FIXTURE_DIRECTORY / "boot.img").read_bytes())
    mutator(image)

    with pytest.raises(BootImageError, match=message):
        parse_boot_image(io.BytesIO(image), len(image), kind="boot")


def test_vendor_boot_parser_rejects_overlapping_ramdisk_fragments() -> None:
    """Two fragment table entries cannot point at overlapping bytes."""
    image = bytearray((FIXTURE_DIRECTORY / "vendor_boot.img").read_bytes())
    page_size = struct.unpack_from("<I", image, 12)[0]
    ramdisk_size = struct.unpack_from("<I", image, 24)[0]
    dtb_size = struct.unpack_from("<I", image, 2100)[0]
    header_size = struct.unpack_from("<I", image, 2096)[0]
    table_offset = (
        (header_size + page_size - 1) // page_size * page_size
        + (ramdisk_size + page_size - 1) // page_size * page_size
        + (dtb_size + page_size - 1) // page_size * page_size
    )
    first_offset = struct.unpack_from("<I", image, table_offset + 4)[0]
    struct.pack_into("<I", image, table_offset + 108 + 4, first_offset)

    with pytest.raises(BootImageError, match="entries overlap"):
        parse_vendor_boot_image(io.BytesIO(image), len(image))


def test_vendor_boot_parser_rejects_gaps_in_ramdisk_fragment_coverage() -> None:
    """Every vendor ramdisk byte must belong to exactly one fragment."""
    image = bytearray((FIXTURE_DIRECTORY / "vendor_boot.img").read_bytes())
    page_size = struct.unpack_from("<I", image, 12)[0]
    ramdisk_size = struct.unpack_from("<I", image, 24)[0]
    dtb_size = struct.unpack_from("<I", image, 2100)[0]
    header_size = struct.unpack_from("<I", image, 2096)[0]
    table_offset = (
        (header_size + page_size - 1) // page_size * page_size
        + (ramdisk_size + page_size - 1) // page_size * page_size
        + (dtb_size + page_size - 1) // page_size * page_size
    )
    struct.pack_into("<I", image, table_offset, 17)

    with pytest.raises(BootImageError, match="do not cover the ramdisk"):
        parse_vendor_boot_image(io.BytesIO(image), len(image))


@pytest.mark.parametrize(
    ("offset", "value", "message"),
    (
        (12, 1024, "invalid page size"),
        (2112, 325, "invalid ramdisk table"),
    ),
)
def test_vendor_boot_parser_rejects_unsupported_layout_values(
    offset: int,
    value: int,
    message: str,
) -> None:
    """Unsupported page sizes and inconsistent table dimensions are rejected."""
    image = bytearray((FIXTURE_DIRECTORY / "vendor_boot.img").read_bytes())
    struct.pack_into("<I", image, offset, value)

    with pytest.raises(BootImageError, match=message):
        parse_vendor_boot_image(io.BytesIO(image), len(image))


def test_boot_parser_rejects_truncated_image() -> None:
    """A short header fails before any payload access."""
    with pytest.raises(BootImageError, match="header exceeds"):
        parse_boot_image(io.BytesIO(b"ANDROID!"), 8, kind="boot")
