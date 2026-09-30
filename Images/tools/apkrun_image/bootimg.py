"""Read Android boot v4 and vendor_boot v4 image sections."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum
from typing import BinaryIO, Literal

BOOT_PAGE_SIZE = 4096
BOOT_HEADER_V4_SIZE = 1584
VENDOR_BOOT_HEADER_V4_SIZE = 2128
VENDOR_RAMDISK_TABLE_ENTRY_SIZE = 108
MAX_VENDOR_RAMDISK_TABLE_SIZE = 16 * 1024 * 1024
MAX_VENDOR_RAMDISK_ENTRIES = 4096
SUPPORTED_VENDOR_BOOT_PAGE_SIZES = frozenset({2048, 4096, 8192, 16384})


class BootImageError(Exception):
    """A boot image is truncated, malformed, or uses an unsupported format."""


class RamdiskType(IntEnum):
    """Vendor boot ramdisk fragment types defined by the boot image format."""

    NONE = 0
    PLATFORM = 1
    RECOVERY = 2
    DLKM = 3


@dataclass(frozen=True)
class ImageSection:
    """A byte range within one Android image file."""

    offset: int
    size: int


@dataclass(frozen=True)
class BootImage:
    """The relevant sections and metadata from a boot or init_boot v4 image."""

    kind: Literal["boot", "init_boot"]
    header_version: int
    header_size: int
    page_size: int
    kernel: ImageSection
    ramdisk: ImageSection
    signature: ImageSection
    os_version: int
    cmdline: str


@dataclass(frozen=True)
class VendorRamdiskFragment:
    """One vendor ramdisk table entry and its byte range in vendor_boot."""

    name: str
    kind: RamdiskType
    offset: int
    size: int
    board_id: tuple[int, ...]
    section: ImageSection


@dataclass(frozen=True)
class VendorBootImage:
    """The relevant sections and metadata from a vendor_boot v4 image."""

    header_version: int
    header_size: int
    page_size: int
    vendor_ramdisk_size: int
    fragments: tuple[VendorRamdiskFragment, ...]
    dtb: ImageSection
    bootconfig: ImageSection
    cmdline: str


def _validate_image_size(image_size: int) -> None:
    """Reject invalid sizes before they are used in offset arithmetic."""
    if isinstance(image_size, bool) or not isinstance(image_size, int) or image_size < 0:
        raise BootImageError("Android image has an invalid file size.")


def _read_at(stream: BinaryIO, image_size: int, offset: int, size: int, name: str) -> bytes:
    """Read an exact, file-bounded range from a seekable image stream."""
    if offset < 0 or size < 0 or offset > image_size or size > image_size - offset:
        raise BootImageError(f"{name} exceeds the Android image file size.")
    try:
        stream.seek(offset)
        value = stream.read(size)
    except (OSError, ValueError) as error:
        raise BootImageError(f"Could not read {name} from the Android image: {error}.") from None
    if len(value) != size:
        raise BootImageError(f"{name} is truncated in the Android image.")
    return value


def _uint32(header: bytes, offset: int) -> int:
    """Read a little-endian 32-bit field from a previously checked header."""
    return struct.unpack_from("<I", header, offset)[0]


def _aligned_size(size: int, alignment: int) -> int:
    """Round a byte count up to the next positive alignment boundary."""
    return (size + alignment - 1) // alignment * alignment


def _section(image_size: int, offset: int, size: int, name: str) -> ImageSection:
    """Validate and create an image section."""
    if offset < 0 or size < 0 or offset > image_size or size > image_size - offset:
        raise BootImageError(f"{name} section exceeds the Android image file size.")
    return ImageSection(offset=offset, size=size)


def _decode_utf8_c_string(value: bytes, name: str) -> str:
    """Decode a NUL-terminated UTF-8 field, as the vendored AOSP tool does."""
    try:
        return value.split(b"\x00", 1)[0].decode("utf-8")
    except UnicodeDecodeError:
        raise BootImageError(f"{name} contains invalid UTF-8 bytes.") from None


def parse_boot_image(
    stream: BinaryIO,
    image_size: int,
    *,
    kind: Literal["boot", "init_boot"],
) -> BootImage:
    """Parse the v4 header and section offsets of boot.img or init_boot.img."""
    _validate_image_size(image_size)
    header = _read_at(stream, image_size, 0, BOOT_HEADER_V4_SIZE, "boot v4 header")
    if header[:8] != b"ANDROID!":
        raise BootImageError("Android boot image has invalid magic.")

    kernel_size = _uint32(header, 8)
    ramdisk_size = _uint32(header, 12)
    os_version = _uint32(header, 16)
    header_size = _uint32(header, 20)
    header_version = _uint32(header, 40)
    signature_size = _uint32(header, 1580)
    if header_version != 4:
        raise BootImageError(f"Android boot image header version {header_version} is not v4.")
    if header_size != BOOT_HEADER_V4_SIZE:
        raise BootImageError(
            f"Android boot v4 header size {header_size} is not {BOOT_HEADER_V4_SIZE}."
        )
    if kind == "boot" and kernel_size == 0:
        raise BootImageError("boot image has an empty kernel section.")
    if kind == "init_boot" and kernel_size != 0:
        raise BootImageError("init_boot image has a non-empty kernel section.")

    cmdline = _decode_utf8_c_string(header[44:1580], "boot command line")
    kernel_offset = BOOT_PAGE_SIZE
    ramdisk_offset = kernel_offset + _aligned_size(kernel_size, BOOT_PAGE_SIZE)
    signature_offset = ramdisk_offset + _aligned_size(ramdisk_size, BOOT_PAGE_SIZE)
    return BootImage(
        kind=kind,
        header_version=header_version,
        header_size=header_size,
        page_size=BOOT_PAGE_SIZE,
        kernel=_section(image_size, kernel_offset, kernel_size, "kernel"),
        ramdisk=_section(image_size, ramdisk_offset, ramdisk_size, "ramdisk"),
        signature=_section(image_size, signature_offset, signature_size, "boot signature"),
        os_version=os_version,
        cmdline=cmdline,
    )


def parse_vendor_boot_image(stream: BinaryIO, image_size: int) -> VendorBootImage:
    """Parse a v4 vendor_boot header, fragment table, DTB, and bootconfig ranges."""
    _validate_image_size(image_size)
    header = _read_at(
        stream,
        image_size,
        0,
        VENDOR_BOOT_HEADER_V4_SIZE,
        "vendor_boot v4 header",
    )
    if header[:8] != b"VNDRBOOT":
        raise BootImageError("vendor_boot image has invalid magic.")

    header_version = _uint32(header, 8)
    page_size = _uint32(header, 12)
    vendor_ramdisk_size = _uint32(header, 24)
    header_size = _uint32(header, 2096)
    dtb_size = _uint32(header, 2100)
    table_size = _uint32(header, 2112)
    entry_count = _uint32(header, 2116)
    entry_size = _uint32(header, 2120)
    bootconfig_size = _uint32(header, 2124)

    if header_version != 4:
        raise BootImageError(f"vendor_boot image header version {header_version} is not v4.")
    if header_size < VENDOR_BOOT_HEADER_V4_SIZE:
        raise BootImageError(
            f"vendor_boot v4 header size {header_size} is smaller than "
            f"{VENDOR_BOOT_HEADER_V4_SIZE}."
        )
    if page_size not in SUPPORTED_VENDOR_BOOT_PAGE_SIZES:
        raise BootImageError("vendor_boot image has an invalid page size.")
    if (
        entry_size < VENDOR_RAMDISK_TABLE_ENTRY_SIZE
        or entry_count > MAX_VENDOR_RAMDISK_ENTRIES
        or table_size > MAX_VENDOR_RAMDISK_TABLE_SIZE
        or table_size != entry_count * entry_size
    ):
        raise BootImageError("vendor_boot image has an invalid ramdisk table.")

    header_pages_size = _aligned_size(header_size, page_size)
    ramdisk_offset = header_pages_size
    ramdisk = _section(image_size, ramdisk_offset, vendor_ramdisk_size, "vendor ramdisk")
    dtb_offset = _aligned_size(ramdisk.offset + ramdisk.size, page_size)
    dtb = _section(image_size, dtb_offset, dtb_size, "vendor DTB")
    table_offset = _aligned_size(dtb.offset + dtb.size, page_size)
    table = _section(image_size, table_offset, table_size, "vendor ramdisk table")
    bootconfig_offset = _aligned_size(table.offset + table.size, page_size)
    bootconfig = _section(image_size, bootconfig_offset, bootconfig_size, "vendor bootconfig")

    table_bytes = _read_at(
        stream,
        image_size,
        table.offset,
        table.size,
        "vendor ramdisk table",
    )
    fragments: list[VendorRamdiskFragment] = []
    occupied_ranges: list[tuple[int, int]] = []
    for index in range(entry_count):
        entry_offset = index * entry_size
        entry = table_bytes[entry_offset : entry_offset + VENDOR_RAMDISK_TABLE_ENTRY_SIZE]
        if len(entry) != VENDOR_RAMDISK_TABLE_ENTRY_SIZE:
            raise BootImageError(f"vendor ramdisk table entry {index} is truncated.")
        size, relative_offset, type_value = struct.unpack_from("<III", entry)
        try:
            fragment_type = RamdiskType(type_value)
        except ValueError:
            raise BootImageError(
                f"vendor ramdisk table entry {index} has unsupported type {type_value}."
            ) from None
        if relative_offset > vendor_ramdisk_size or size > vendor_ramdisk_size - relative_offset:
            raise BootImageError(f"vendor ramdisk table entry {index} exceeds the ramdisk.")
        fragment_name = _decode_utf8_c_string(
            entry[12:44],
            f"vendor ramdisk table entry {index} name",
        )
        board_id = struct.unpack_from("<16I", entry, 44)
        if size:
            occupied_ranges.append((relative_offset, relative_offset + size))
        fragments.append(
            VendorRamdiskFragment(
                name=fragment_name,
                kind=fragment_type,
                offset=relative_offset,
                size=size,
                board_id=board_id,
                section=ImageSection(offset=ramdisk.offset + relative_offset, size=size),
            )
        )

    ordered_ranges = sorted(occupied_ranges)
    covered_size = 0
    for start, end in ordered_ranges:
        if start < covered_size:
            raise BootImageError("vendor ramdisk table entries overlap.")
        if start > covered_size:
            raise BootImageError("vendor ramdisk table entries do not cover the ramdisk.")
        covered_size = end
    if covered_size != vendor_ramdisk_size:
        raise BootImageError("vendor ramdisk table entries do not cover the ramdisk.")

    cmdline = _decode_utf8_c_string(header[28:2076], "vendor_boot command line")
    return VendorBootImage(
        header_version=header_version,
        header_size=header_size,
        page_size=page_size,
        vendor_ramdisk_size=vendor_ramdisk_size,
        fragments=tuple(fragments),
        dtb=dtb,
        bootconfig=bootconfig,
        cmdline=cmdline,
    )


def read_section(
    stream: BinaryIO,
    image_size: int,
    section: ImageSection,
    name: str,
) -> bytes:
    """Read one already-validated image section."""
    return _read_at(stream, image_size, section.offset, section.size, f"{name} section")
