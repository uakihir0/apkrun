"""Content-based inventory of Android image archives and directories."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import struct
import sys
import tempfile
import unicodedata
import zipfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from functools import partial
from pathlib import Path, PurePosixPath
from typing import BinaryIO

from apkrun_image import __version__
from apkrun_image.lp import LpMetadataError, read_dynamic_partitions
from apkrun_image.sparse import (
    SPARSE_MAGIC,
    SparseHeader,
    SparseImageError,
    iter_chunks,
    read_header,
    read_range,
)

MAX_TEXT_SIZE = 1024 * 1024
MAX_VENDOR_RAMDISK_TABLE_SIZE = 16 * 1024 * 1024
MAX_VENDOR_RAMDISK_ENTRIES = 4096
MAX_ARCHIVE_SIZE = 16 * 1024 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 4096
MAX_CENTRAL_DIRECTORY_SIZE = 64 * 1024 * 1024
MAX_ZIP64_RECORD_SIZE = 1024 * 1024
MAX_MEMBER_SIZE = 16 * 1024 * 1024 * 1024
MAX_TOTAL_INPUT_SIZE = 64 * 1024 * 1024 * 1024
HASH_CHUNK_SIZE = 1024 * 1024
VENDOR_RAMDISK_TYPES = {
    0: "NONE",
    1: "PLATFORM",
    2: "RECOVERY",
    3: "DLKM",
}
AVB_ALGORITHMS = {
    0: "NONE",
    1: "SHA256_RSA2048",
    2: "SHA256_RSA4096",
    3: "SHA256_RSA8192",
    4: "SHA512_RSA2048",
    5: "SHA512_RSA4096",
    6: "SHA512_RSA8192",
    7: "MLDSA65",
    8: "MLDSA87",
}
AVB_DESCRIPTOR_TYPES = {
    0: "property",
    1: "hashtree",
    2: "hash",
    3: "kernelCmdline",
    4: "chainPartition",
}


def _avb_digest_size(algorithm: str) -> int | None:
    """Match the digest names accepted by the pinned AOSP avbtool."""
    if algorithm.lower() == "blake2b-256":
        return 32
    try:
        return hashlib.new(algorithm).digest_size
    except (TypeError, ValueError):
        return None


class InventoryError(ValueError):
    """An invalid or unsupported Android artifact set."""


@dataclass(frozen=True)
class InputFile:
    """One regular file and a way to reopen its read-only stream."""

    path: str
    size: int
    open_stream: Callable[[], BinaryIO]
    source_path: Path | None = None
    expected_version: tuple[int, int, int, int, int] | None = None


@dataclass(frozen=True)
class Classification:
    """Stable inventory classification for one file."""

    kind: str
    probable_purpose: str
    details: dict[str, object]
    name_mismatch: bool = False

    def as_dict(self, path: str, size: int, sha256: str) -> dict[str, object]:
        """Serialize one file entry."""
        value: dict[str, object] = {
            "details": self.details,
            "kind": self.kind,
            "path": path,
            "probablePurpose": self.probable_purpose,
            "sha256": sha256,
            "size": size,
        }
        if self.name_mismatch:
            value["nameMismatch"] = True
        return value


def _read_at(stream: BinaryIO, offset: int, size: int) -> bytes:
    """Read a range without changing the caller's position."""
    stream.seek(offset)
    return stream.read(size)


def _read_c_string(value: bytes) -> str:
    """Decode a NUL-terminated header string for human-readable metadata."""
    return value.split(b"\0", 1)[0].decode("ascii", errors="replace").strip()


def _os_version(value: int) -> dict[str, str] | None:
    """Decode the packed Android boot-header release and security patch."""
    if value == 0:
        return None
    major = (value >> 25) & 0x7F
    minor = (value >> 18) & 0x7F
    patch = (value >> 11) & 0x7F
    year = ((value >> 4) & 0x7F) + 2000
    month = value & 0x0F
    details = {"release": f"{major}.{minor}.{patch}"}
    if 1 <= month <= 12:
        details["securityPatch"] = f"{year:04d}-{month:02d}"
    return details


def _parse_boot_image(stream: BinaryIO, file_size: int) -> Classification:
    """Read and validate Android boot image headers and their payload bounds."""
    header = _read_at(stream, 0, 48)
    if len(header) < 48 or header[:8] != b"ANDROID!":
        raise InventoryError("truncated Android boot image header")
    header_version = struct.unpack_from("<I", header, 40)[0]
    kernel_size = struct.unpack_from("<I", header, 8)[0]
    signature_size = 0
    if header_version >= 3:
        ramdisk_size = struct.unpack_from("<I", header, 12)[0]
        minimum_header_size = 1580 if header_version == 3 else 1584
        if header_version > 4 or file_size < minimum_header_size:
            raise InventoryError(
                f"unsupported or truncated Android boot image version {header_version}"
            )
        header_size = struct.unpack_from("<I", header, 20)[0]
        if header_size < minimum_header_size or header_size > 4096:
            raise InventoryError("Android boot image has an invalid header size")
        if header_version == 4:
            signature_header = _read_at(stream, 1580, 4)
            if len(signature_header) != 4:
                raise InventoryError("truncated Android boot image signature size")
            signature_size = struct.unpack("<I", signature_header)[0]
            if signature_size > 4096:
                raise InventoryError("Android boot image has an invalid signature size")
        page_size = 4096
        payload_offset = _align(header_size, page_size)
        os_version_value = struct.unpack_from("<I", header, 16)[0]
        command_line = _read_c_string(_read_at(stream, 44, 1536))
    else:
        ramdisk_size = struct.unpack_from("<I", header, 16)[0]
        minimum_header_size = {0: 1632, 1: 1648, 2: 1660}[header_version]
        if file_size < minimum_header_size:
            raise InventoryError("truncated legacy Android boot image header")
        page_size = struct.unpack_from("<I", header, 36)[0]
        if (
            page_size < minimum_header_size
            or page_size > 1024 * 1024
            or page_size & (page_size - 1)
        ):
            raise InventoryError(f"Android boot image has an invalid page size {page_size}")
        payload_offset = page_size
        os_version_value = struct.unpack_from("<I", header, 44)[0]
        legacy_command_line = _read_c_string(_read_at(stream, 64, 512))
        extra_command_line = _read_c_string(_read_at(stream, 608, 1024))
        command_line = " ".join(
            part
            for part in (
                legacy_command_line,
                extra_command_line,
            )
            if part
        )
    if payload_offset > file_size or kernel_size > file_size - payload_offset:
        raise InventoryError("Android boot image kernel extends past the file size")
    ramdisk_offset = _align(payload_offset + kernel_size, page_size)
    if ramdisk_size and (ramdisk_offset > file_size or ramdisk_size > file_size - ramdisk_offset):
        raise InventoryError("Android boot image ramdisk extends past the file size")
    if signature_size:
        signature_offset = _align(ramdisk_offset + ramdisk_size, page_size)
        if signature_offset > file_size or signature_size > file_size - signature_offset:
            raise InventoryError("Android boot image signature extends past the file size")
    boot_kind = "boot" if kernel_size > 0 else "init_boot" if ramdisk_size > 0 else "unknown"
    details: dict[str, object] = {
        "bootKind": boot_kind,
        "cmdline": command_line,
        "headerVersion": header_version,
        "kernelSize": kernel_size,
        "ramdiskSize": ramdisk_size,
    }
    if signature_size:
        details["bootSignatureSize"] = signature_size
    version = _os_version(os_version_value)
    if version is not None:
        details["osVersion"] = version
    purpose = (
        "boot partition (kernel)"
        if boot_kind == "boot"
        else "generic ramdisk partition"
        if boot_kind == "init_boot"
        else "Android boot image"
    )
    return Classification("bootImage", purpose, details)


def _align(value: int, alignment: int) -> int:
    """Round an offset up to a positive power-of-two page size."""
    if alignment <= 0:
        raise InventoryError("vendor boot image has an invalid page size")
    return (value + alignment - 1) // alignment * alignment


def _parse_vendor_boot_image(stream: BinaryIO, file_size: int) -> Classification:
    """Read the v3/v4 vendor boot header and v4 vendor ramdisk table."""
    header = _read_at(stream, 0, 2128)
    if len(header) < 2112 or header[:8] != b"VNDRBOOT":
        raise InventoryError("truncated vendor boot image header")
    header_version, page_size = struct.unpack_from("<II", header, 8)
    ramdisk_size = struct.unpack_from("<I", header, 24)[0]
    command_line = _read_c_string(header[28 : 28 + 2048])
    header_size, dtb_size = struct.unpack_from("<II", header, 2096)
    if header_version not in {3, 4}:
        raise InventoryError(f"unsupported vendor boot image header version {header_version}")
    if page_size == 0 or header_size < 2112 or header_size > file_size:
        raise InventoryError("vendor boot image has invalid header dimensions")
    ramdisk_offset = _align(header_size, page_size)
    if ramdisk_offset > file_size or ramdisk_size > file_size - ramdisk_offset:
        raise InventoryError("vendor boot image ramdisk exceeds the file size")
    dtb_offset = _align(ramdisk_offset + ramdisk_size, page_size)
    if dtb_offset > file_size or dtb_size > file_size - dtb_offset:
        raise InventoryError("vendor boot image DTB exceeds the file size")

    ramdisks: list[dict[str, object]] = []
    bootconfig_size = 0
    if header_version == 4:
        if len(header) < 2128 or header_size < 2128:
            raise InventoryError("truncated vendor boot v4 header")
        table_size, entry_count, entry_size, bootconfig_size = struct.unpack_from(
            "<IIII", header, 2112
        )
        if (
            entry_size < 108
            or entry_count > table_size // entry_size
            or entry_count > MAX_VENDOR_RAMDISK_ENTRIES
            or table_size > MAX_VENDOR_RAMDISK_TABLE_SIZE
        ):
            raise InventoryError("vendor boot image has an invalid ramdisk table")
        table_offset = _align(dtb_offset + dtb_size, page_size)
        if table_offset + table_size + bootconfig_size > file_size:
            raise InventoryError("vendor boot image ramdisk table exceeds the file size")
        for index in range(entry_count):
            entry_offset = index * entry_size
            entry = _read_at(stream, table_offset + entry_offset, 108)
            if len(entry) != 108:
                raise InventoryError("truncated vendor boot ramdisk table")
            size, offset, ramdisk_type = struct.unpack_from("<III", entry)
            name = _read_c_string(entry[12:44])
            if offset > ramdisk_size or size > ramdisk_size - offset:
                raise InventoryError(f"vendor boot ramdisk table entry {index} exceeds the ramdisk")
            ramdisks.append(
                {
                    "name": name,
                    "size": size,
                    "type": VENDOR_RAMDISK_TYPES.get(ramdisk_type, f"UNKNOWN_{ramdisk_type}"),
                }
            )

    details: dict[str, object] = {
        "bootconfigSize": bootconfig_size,
        "cmdline": command_line,
        "dtbSize": dtb_size,
        "headerVersion": header_version,
        "pageSize": page_size,
        "ramdisks": ramdisks,
    }
    return Classification(
        "vendorBootImage",
        "vendor boot partition (vendor ramdisk, cmdline, and bootconfig)",
        details,
    )


def _decode_avb_partition_name(payload: bytes, descriptor_type: int) -> str | None:
    """Validate known AVB descriptor layouts and return an optional partition name."""
    fixed_size: int
    variable_sizes: tuple[int, ...]
    if descriptor_type == 2:
        fixed_size = 116
        if len(payload) < fixed_size:
            raise InventoryError("truncated AVB hash descriptor")
        name_size, salt_size, digest_size = struct.unpack_from(">III", payload, 40)
        algorithm_bytes = payload[8:40].split(b"\0", 1)[0]
        try:
            algorithm = algorithm_bytes.decode("ascii")
        except UnicodeDecodeError as error:
            raise InventoryError("AVB hash descriptor has a non-ASCII algorithm") from error
        expected_digest_size = _avb_digest_size(algorithm)
        if expected_digest_size is None or digest_size not in {0, expected_digest_size}:
            raise InventoryError("AVB hash descriptor has an invalid hash algorithm or digest size")
        variable_sizes = (name_size, salt_size, digest_size)
    elif descriptor_type == 1:
        fixed_size = 164
        if len(payload) < fixed_size:
            raise InventoryError("truncated AVB hashtree descriptor")
        name_size, salt_size, digest_size = struct.unpack_from(">III", payload, 88)
        algorithm_bytes = payload[56:88].split(b"\0", 1)[0]
        try:
            algorithm = algorithm_bytes.decode("ascii")
        except UnicodeDecodeError as error:
            raise InventoryError("AVB hashtree descriptor has a non-ASCII algorithm") from error
        expected_digest_size = _avb_digest_size(algorithm)
        if expected_digest_size is None or digest_size not in {0, expected_digest_size}:
            raise InventoryError(
                "AVB hashtree descriptor has an invalid hash algorithm or digest size"
            )
        variable_sizes = (name_size, salt_size, digest_size)
    elif descriptor_type == 4:
        fixed_size = 76
        if len(payload) < fixed_size:
            raise InventoryError("truncated AVB chain partition descriptor")
        name_size, public_key_size = struct.unpack_from(">II", payload, 4)
        variable_sizes = (name_size, public_key_size)
    elif descriptor_type == 0:
        if len(payload) < 16:
            raise InventoryError("truncated AVB property descriptor")
        key_size, value_size = struct.unpack_from(">QQ", payload)
        used_size = 16 + key_size + 1 + value_size + 1
        if _align(used_size, 8) != len(payload):
            raise InventoryError("AVB property descriptor has an invalid size")
        key_end = 16 + key_size
        value_start = key_end + 1
        value_end = value_start + value_size
        if (
            key_end >= len(payload)
            or payload[key_end] != 0
            or value_end >= len(payload)
            or payload[value_end] != 0
            or any(payload[value_end + 1 :])
        ):
            raise InventoryError("AVB property descriptor has invalid strings or padding")
        return None
    elif descriptor_type == 3:
        if len(payload) < 8:
            raise InventoryError("truncated AVB kernel command-line descriptor")
        command_size = struct.unpack_from(">I", payload, 4)[0]
        used_size = 8 + command_size
        if _align(used_size, 8) != len(payload) or any(payload[used_size:]):
            raise InventoryError("AVB kernel command-line descriptor has an invalid size")
        try:
            payload[8:used_size].decode("utf-8")
        except UnicodeDecodeError as error:
            raise InventoryError("AVB kernel command line is not UTF-8") from error
        return None
    else:
        return None

    used_size = fixed_size + sum(variable_sizes)
    if _align(used_size, 8) != len(payload):
        raise InventoryError("AVB descriptor has an invalid size or alignment")
    if any(payload[used_size:]):
        raise InventoryError("AVB descriptor has nonzero padding")
    name_size = variable_sizes[0]
    try:
        name = payload[fixed_size : fixed_size + name_size].decode("utf-8")
    except UnicodeDecodeError as error:
        raise InventoryError("AVB partition name is not UTF-8") from error
    if "/" in name or "\\" in name or "\0" in name:
        raise InventoryError("AVB descriptor has an invalid partition name")
    return name or None


def _parse_vbmeta(stream: BinaryIO, file_size: int) -> Classification:
    """Parse the vbmeta header and its bounded descriptor table."""
    header = _read_at(stream, 0, 256)
    if len(header) < 176 or header[:4] != b"AVB0":
        raise InventoryError("truncated vbmeta header")
    authentication_size, auxiliary_size = struct.unpack_from(">QQ", header, 12)
    algorithm_type = struct.unpack_from(">I", header, 28)[0]
    descriptors_offset, descriptors_size = struct.unpack_from(">QQ", header, 96)
    rollback_index = struct.unpack_from(">Q", header, 112)[0]
    flags = struct.unpack_from(">I", header, 120)[0]
    if 256 + authentication_size + auxiliary_size > file_size:
        raise InventoryError("vbmeta authentication and auxiliary blocks exceed the file size")
    if descriptors_size > auxiliary_size or descriptors_offset > auxiliary_size - descriptors_size:
        raise InventoryError("vbmeta descriptor table exceeds the auxiliary block")
    if descriptors_size > 16 * 1024 * 1024:
        raise InventoryError("vbmeta descriptor table is unreasonably large")

    descriptor_start = 256 + authentication_size + descriptors_offset
    descriptor_bytes = _read_at(stream, descriptor_start, descriptors_size)
    if len(descriptor_bytes) != descriptors_size:
        raise InventoryError("truncated vbmeta descriptor table")
    descriptors: list[dict[str, str]] = []
    offset = 0
    while offset < len(descriptor_bytes):
        if len(descriptor_bytes) - offset < 16:
            raise InventoryError("truncated vbmeta descriptor header")
        descriptor_type, following_size = struct.unpack_from(">QQ", descriptor_bytes, offset)
        if following_size % 8:
            raise InventoryError("AVB descriptor size is not 8-byte aligned")
        end = offset + 16 + following_size
        if end > len(descriptor_bytes):
            raise InventoryError("vbmeta descriptor exceeds the descriptor table")
        descriptor = {"type": AVB_DESCRIPTOR_TYPES.get(descriptor_type, "unknown")}
        partition = _decode_avb_partition_name(
            descriptor_bytes[offset + 16 : end],
            descriptor_type,
        )
        if partition is not None:
            descriptor["partition"] = partition
        descriptors.append(descriptor)
        offset = end

    details: dict[str, object] = {
        "algorithm": AVB_ALGORITHMS.get(algorithm_type, f"UNKNOWN_{algorithm_type}"),
        "descriptors": descriptors,
        "flags": flags,
        "rollbackIndex": rollback_index,
    }
    return Classification("vbmeta", "Android Verified Boot metadata", details)


def _parse_filesystem_at(
    read_at: Callable[[int, int], bytes],
    image_size: int,
) -> Classification | None:
    """Detect ext4, EROFS, or F2FS from its superblock."""
    superblock = read_at(1024, 1024)
    if len(superblock) < 1024:
        return None

    if struct.unpack_from("<H", superblock, 56)[0] == 0xEF53:
        block_count_low = struct.unpack_from("<I", superblock, 4)[0]
        log_block_size = struct.unpack_from("<I", superblock, 24)[0]
        feature_incompat = struct.unpack_from("<I", superblock, 96)[0]
        if log_block_size > 6:
            raise InventoryError(f"invalid ext4 log block size {log_block_size}")
        block_count = block_count_low
        if feature_incompat & 0x80:
            block_count |= struct.unpack_from("<I", superblock, 336)[0] << 32
        filesystem_size = block_count * (1024 << log_block_size)
        if filesystem_size > image_size:
            raise InventoryError("ext4 filesystem size extends past the image")
        return Classification(
            "filesystem",
            "ext4 filesystem image",
            {"size": filesystem_size, "type": "ext4"},
        )

    magic = struct.unpack_from("<I", superblock, 0)[0]
    if magic == 0xE0F5E1E2:
        block_size_bits = superblock[12]
        block_count = struct.unpack_from("<I", superblock, 36)[0]
        if block_size_bits > 16:
            raise InventoryError(f"invalid EROFS block size {block_size_bits}")
        filesystem_size = block_count << block_size_bits
        if filesystem_size > image_size:
            raise InventoryError("EROFS filesystem size extends past the image")
        return Classification(
            "filesystem",
            "EROFS filesystem image",
            {"size": filesystem_size, "type": "erofs"},
        )
    if magic == 0xF2F52010:
        log_block_size = struct.unpack_from("<I", superblock, 16)[0]
        block_count = struct.unpack_from("<Q", superblock, 36)[0]
        if log_block_size > 16:
            raise InventoryError(f"invalid F2FS log block size {log_block_size}")
        filesystem_size = block_count * (1 << log_block_size)
        if filesystem_size > image_size:
            raise InventoryError("F2FS filesystem size extends past the image")
        return Classification(
            "filesystem",
            "F2FS filesystem image",
            {"size": filesystem_size, "type": "f2fs"},
        )
    return None


def _parse_text(stream: BinaryIO, file_size: int) -> Classification | None:
    """Read small UTF-8 metadata files without treating binary data as text."""
    if file_size > MAX_TEXT_SIZE:
        return None
    stream.seek(0)
    content = stream.read(file_size)
    if b"\0" in content:
        return None
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return None
    lines = text.splitlines()
    values: dict[str, str] = {}
    is_key_value = True
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            is_key_value = False
            break
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in values:
            is_key_value = False
            break
        values[key] = value.strip()
    details: dict[str, object] = {"values": values} if is_key_value and values else {"lines": lines}
    purpose = (
        "device information key/value metadata" if "values" in details else "build metadata text"
    )
    return Classification("text", purpose, details)


def _expanded_sparse_content(
    stream: BinaryIO,
    header: SparseHeader,
) -> tuple[str, dict[str, object]]:
    """Classify the expanded content without materializing a sparse image."""
    if header.logical_size >= 8192:
        logical_partitions = read_dynamic_partitions(stream, sparse=True)
        if logical_partitions is not None:
            return "dynamicPartitions", logical_partitions.as_dict()

    if header.logical_size >= 2048:

        def read_at(offset: int, size: int) -> bytes:
            return read_range(stream, offset, size)

        filesystem = _parse_filesystem_at(read_at, header.logical_size)
        if filesystem is not None:
            return "filesystem", filesystem.details

    magic_size = min(8, header.logical_size)
    magic = read_range(stream, 0, magic_size).hex()
    return "unknown", {"magic": magic}


def _classification_for_name(classification: Classification, path: str) -> Classification:
    """Set the documented mismatch flag from a content-based kind."""
    posix_path = PurePosixPath(path)
    base_name = posix_path.stem if posix_path.suffix[1:] == "img" else posix_path.name
    expected: str | None = None
    if base_name == "boot":
        expected = "boot"
    elif base_name == "init_boot":
        expected = "init_boot"
    elif base_name == "vendor_boot":
        expected = "vendor_boot"
    elif base_name == "vbmeta" or base_name.startswith("vbmeta_"):
        expected = "vbmeta"
    elif base_name == "super":
        expected = "super"
    elif base_name == "userdata":
        expected = "userdata"
    if expected is None:
        return classification

    details = classification.details
    if expected in {"boot", "init_boot"}:
        matches = classification.kind == "bootImage" and details.get("bootKind") == expected
    elif expected == "vendor_boot":
        matches = classification.kind == "vendorBootImage"
    elif expected == "vbmeta":
        matches = classification.kind == "vbmeta"
    elif expected == "super":
        sparse_content = details.get("content")
        matches = classification.kind == "dynamicPartitions" or (
            classification.kind == "sparse"
            and isinstance(sparse_content, dict)
            and sparse_content.get("kind") == "dynamicPartitions"
        )
    else:
        sparse_content = details.get("content")
        matches = classification.kind == "filesystem" or (
            classification.kind == "sparse"
            and isinstance(sparse_content, dict)
            and sparse_content.get("kind") == "filesystem"
        )
    return Classification(
        kind=classification.kind,
        probable_purpose=classification.probable_purpose,
        details=classification.details,
        name_mismatch=not matches,
    )


def _classify(stream: BinaryIO, file_size: int, path: str) -> Classification:
    """Classify file content; the name is used only for nameMismatch."""
    prefix = _read_at(stream, 0, 8)
    if prefix == b"ANDROID!":
        result = _parse_boot_image(stream, file_size)
    elif prefix == b"VNDRBOOT":
        result = _parse_vendor_boot_image(stream, file_size)
    elif prefix[:4] == b"AVB0":
        result = _parse_vbmeta(stream, file_size)
    elif len(prefix) >= 4 and struct.unpack("<I", prefix[:4])[0] == SPARSE_MAGIC:
        try:
            header = read_header(stream)
            for _chunk in iter_chunks(stream, header):
                pass
            content_kind, content_details = _expanded_sparse_content(stream, header)
        except (LpMetadataError, SparseImageError) as error:
            raise InventoryError(f"{path}: invalid sparse image: {error}") from error
        details: dict[str, object] = {
            "blockSize": header.block_size,
            "chunkCount": header.total_chunks,
            "content": {"details": content_details, "kind": content_kind},
            "logicalSize": header.logical_size,
            "totalBlocks": header.total_blocks,
        }
        result = Classification(
            "sparse",
            f"sparse image containing {content_kind}",
            details,
        )
    else:
        try:
            logical_partitions = read_dynamic_partitions(stream)
        except LpMetadataError as error:
            raise InventoryError(f"{path}: invalid liblp metadata: {error}") from error
        if logical_partitions is not None:
            result = Classification(
                "dynamicPartitions",
                "dynamic partition metadata",
                logical_partitions.as_dict(),
            )
        else:
            result = _parse_filesystem_at(
                lambda offset, size: _read_at(stream, offset, size),
                file_size,
            )
            if result is None:
                result = _parse_text(stream, file_size)
            if result is None:
                result = Classification(
                    "unknown",
                    "unknown",
                    {"magic": prefix.hex()},
                )

    result = _with_avb_footer(result, stream, file_size)
    return _classification_for_name(result, path)


def _with_avb_footer(
    classification: Classification,
    stream: BinaryIO,
    file_size: int,
) -> Classification:
    """Attach an AVB footer when its magic occupies the final 64 bytes."""
    if file_size < 64:
        return classification
    footer = _read_at(stream, file_size - 64, 64)
    if len(footer) != 64 or footer[:4] != b"AVBf":
        return classification
    _magic, major_version, minor_version, original_size, vbmeta_offset, vbmeta_size = struct.unpack(
        ">4sIIQQQ", footer[:36]
    )
    footer_offset = file_size - 64
    if (
        major_version != 1
        or minor_version > 0
        or original_size > vbmeta_offset
        or vbmeta_offset > footer_offset
        or vbmeta_size == 0
        or vbmeta_size > footer_offset - vbmeta_offset
    ):
        raise InventoryError("invalid AVB footer bounds or version")
    details = dict(classification.details)
    details["avbFooter"] = {
        "originalSize": original_size,
        "vbmetaOffset": vbmeta_offset,
        "vbmetaSize": vbmeta_size,
        "version": f"{major_version}.{minor_version}",
    }
    return Classification(
        classification.kind,
        classification.probable_purpose,
        details,
        classification.name_mismatch,
    )


def _hash_stream(
    stream: BinaryIO,
    expected_size: int,
    path: str,
    *,
    maximum_size: int | None = None,
) -> str:
    """Hash an input file and verify that it did not change while being read."""
    digest = hashlib.sha256()
    size = 0
    while chunk := stream.read(HASH_CHUNK_SIZE):
        digest.update(chunk)
        size += len(chunk)
        if size > expected_size or (maximum_size is not None and size > maximum_size):
            raise InventoryError(f"{path}: input expanded beyond its declared size limit")
    if size != expected_size:
        raise InventoryError(f"{path}: changed size while the inventory was being generated")
    try:
        stream.seek(0)
    except OSError as error:
        raise InventoryError(f"{path}: input stream is not seekable") from error
    return digest.hexdigest()


def _inventory_file(entry: InputFile) -> dict[str, object]:
    """Hash and classify one regular file using read-only access."""
    try:
        with entry.open_stream() as stream:
            initial_version = entry.expected_version
            if entry.source_path is not None:
                opened_stat = os.fstat(stream.fileno())
                if (
                    not stat.S_ISREG(opened_stat.st_mode)
                    or initial_version is None
                    or _file_version(opened_stat) != initial_version
                ):
                    raise InventoryError(f"{entry.path}: input file changed before inventory")
            digest = _hash_stream(
                stream,
                entry.size,
                entry.path,
                maximum_size=MAX_MEMBER_SIZE,
            )
            classification = _classify(stream, entry.size, entry.path)
            if entry.source_path is not None:
                final_stat = os.fstat(stream.fileno())
                path_stat = entry.source_path.lstat()
                if (
                    initial_version is None
                    or _file_version(final_stat) != initial_version
                    or _file_version(path_stat) != initial_version
                    or not stat.S_ISREG(path_stat.st_mode)
                ):
                    raise InventoryError(f"{entry.path}: input file changed during inventory")
    except InventoryError:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        raise InventoryError(f"{entry.path}: could not read input file: {error}") from error
    return classification.as_dict(entry.path, entry.size, digest)


def _validate_member_path(value: str) -> str:
    """Reject archive paths that are absolute, ambiguous, or traverse parents."""
    if not value or "\\" in value or value.startswith("/"):
        raise InventoryError(f"archive contains an unsafe path {value!r}")
    path = PurePosixPath(value)
    if any(part in {"", ".", ".."} for part in value.split("/")):
        raise InventoryError(f"archive contains an unsafe path {value!r}")
    return path.as_posix()


def _directory_entries(directory: Path) -> list[InputFile]:
    """Collect regular files without following symlinks."""
    entries: list[InputFile] = []
    total_size = 0
    for path in directory.rglob("*"):
        try:
            path_stat = path.lstat()
        except OSError as error:
            raise InventoryError(f"{path}: input path changed during inventory") from error
        if stat.S_ISLNK(path_stat.st_mode):
            raise InventoryError(f"input directory contains a symbolic link: {path}")
        if not stat.S_ISREG(path_stat.st_mode):
            continue
        if len(entries) >= MAX_ARCHIVE_ENTRIES:
            raise InventoryError(f"input directory exceeds the {MAX_ARCHIVE_ENTRIES}-file limit")
        if path_stat.st_size > MAX_MEMBER_SIZE:
            raise InventoryError(
                f"{path}: file exceeds the {MAX_MEMBER_SIZE}-byte member-size limit"
            )
        total_size += path_stat.st_size
        if total_size > MAX_TOTAL_INPUT_SIZE:
            raise InventoryError(
                f"input directory exceeds the {MAX_TOTAL_INPUT_SIZE}-byte total-size limit"
            )
        member = path.relative_to(directory).as_posix()
        expected_version = _file_version(path_stat)
        entries.append(
            InputFile(
                path=member,
                size=path_stat.st_size,
                open_stream=partial(
                    _open_directory_file,
                    directory,
                    member,
                    path,
                    expected_version,
                ),
                source_path=path,
                expected_version=expected_version,
            )
        )
    return sorted(entries, key=lambda entry: entry.path.encode("utf-8"))


def _zip_entries(archive: zipfile.ZipFile) -> list[InputFile]:
    """Collect regular archive entries and reject unsafe or duplicate paths."""
    entries: list[InputFile] = []
    seen: set[str] = set()
    infos = archive.infolist()
    if len(infos) > MAX_ARCHIVE_ENTRIES:
        raise InventoryError(f"zip archive exceeds the {MAX_ARCHIVE_ENTRIES}-entry limit")
    total_size = 0
    for info in infos:
        if info.file_size > MAX_MEMBER_SIZE:
            raise InventoryError(
                f"{info.filename}: zip entry exceeds the {MAX_MEMBER_SIZE}-byte size limit"
            )
        total_size += info.file_size
        if total_size > MAX_TOTAL_INPUT_SIZE:
            raise InventoryError(
                f"zip archive exceeds the {MAX_TOTAL_INPUT_SIZE}-byte expanded-size limit"
            )
        if info.is_dir():
            continue
        member = _validate_member_path(info.filename)
        mode = info.external_attr >> 16
        file_type = stat.S_IFMT(mode)
        if file_type == stat.S_IFLNK:
            raise InventoryError(f"archive contains a symbolic link: {member}")
        if file_type not in {0, stat.S_IFREG}:
            raise InventoryError(f"archive contains a non-regular file: {member}")
        if member in seen:
            raise InventoryError(f"archive contains duplicate file path {member!r}")
        seen.add(member)
        entries.append(
            InputFile(
                path=member,
                size=info.file_size,
                open_stream=lambda item=info: archive.open(item, "r"),
            )
        )
    return sorted(entries, key=lambda entry: entry.path.encode("utf-8"))


def _file_version(file_stat: os.stat_result) -> tuple[int, int, int, int, int]:
    """Return identity and timestamps used to detect in-place mutation."""
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
        file_stat.st_ctime_ns,
    )


def _open_directory_file(
    root: Path,
    relative_path: str,
    path: Path,
    expected_version: tuple[int, int, int, int, int],
) -> BinaryIO:
    """Open one inventoried path without following swapped directory symlinks."""
    directory_flags = os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_DIRECTORY", 0)
    directory_descriptor = -1
    file_descriptor = -1
    try:
        directory_descriptor = os.open(root, directory_flags)
        if not stat.S_ISDIR(os.fstat(directory_descriptor).st_mode):
            raise InventoryError(f"{path}: input directory changed before it could be opened")
        components = PurePosixPath(relative_path).parts
        for component in components[:-1]:
            next_descriptor = os.open(
                component,
                directory_flags,
                dir_fd=directory_descriptor,
            )
            previous_descriptor = directory_descriptor
            directory_descriptor = next_descriptor
            os.close(previous_descriptor)
        file_descriptor = os.open(
            components[-1],
            os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=directory_descriptor,
        )
        opened_stat = os.fstat(file_descriptor)
        if not stat.S_ISREG(opened_stat.st_mode) or _file_version(opened_stat) != expected_version:
            raise InventoryError(f"{path}: input file changed before it could be opened")
        stream = os.fdopen(file_descriptor, "rb")
        file_descriptor = -1
        return stream
    except OSError as error:
        raise InventoryError(f"{path}: input file changed before it could be opened") from error
    finally:
        if file_descriptor >= 0:
            os.close(file_descriptor)
        if directory_descriptor >= 0:
            os.close(directory_descriptor)


def _fetch_context(
    directory: Path,
    *,
    expected_name: str | None = None,
) -> dict[str, object] | None:
    """Read validated build provenance for a downloaded archive directory."""
    manifest_path = directory / "fetch.json"
    if not manifest_path.exists():
        return None
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise InventoryError(f"{manifest_path}: fetch metadata must be a regular file")
    try:
        value = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InventoryError(f"{manifest_path}: could not read fetch metadata: {error}") from error
    if (
        not isinstance(value, dict)
        or isinstance(value.get("schemaVersion"), bool)
        or value.get("schemaVersion") != 2
        or value.get("branchProvenance") != "caller-asserted"
    ):
        raise InventoryError(f"{manifest_path}: unsupported fetch metadata format")
    branch = value.get("branch")
    target = value.get("target")
    build_id = value.get("buildId")
    artifacts = value.get("artifacts")
    if (
        not isinstance(branch, str)
        or not branch
        or not isinstance(target, str)
        or not target
        or not isinstance(build_id, str)
        or not build_id
        or not isinstance(artifacts, list)
    ):
        raise InventoryError(f"{manifest_path}: fetch metadata has incomplete build provenance")
    matching: dict[str, object] | None = None
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise InventoryError(f"{manifest_path}: malformed artifact record")
        name = artifact.get("name")
        if (
            not isinstance(name, str)
            or not name
            or PurePosixPath(name).name != name
            or "\\" in name
            or name in {".", ".."}
            or any(
                unicodedata.category(character) in {"Cc", "Cf", "Cs", "Zl", "Zp"}
                for character in name
            )
        ):
            raise InventoryError(f"{manifest_path}: unsafe artifact name")
        if expected_name is not None and name != expected_name:
            continue
        size = artifact.get("size")
        sha256 = artifact.get("sha256")
        if (
            isinstance(size, bool)
            or not isinstance(size, int)
            or size < 1
            or not isinstance(sha256, str)
            or len(sha256) != 64
            or any(character not in "0123456789abcdef" for character in sha256)
        ):
            raise InventoryError(f"{manifest_path}: invalid size or SHA-256 for {name}")
        if matching is not None:
            raise InventoryError(f"{manifest_path}: duplicate artifact record for {name}")
        matching = artifact
    if matching is None:
        if expected_name is not None:
            return None
        if len(artifacts) != 1:
            raise InventoryError(f"{manifest_path}: inventory one downloaded archive at a time")
        artifact = artifacts[0]
        if not isinstance(artifact, dict):
            raise InventoryError(f"{manifest_path}: malformed artifact record")
        name = artifact["name"]
        size = artifact.get("size")
        sha256 = artifact.get("sha256")
        if (
            isinstance(size, bool)
            or not isinstance(size, int)
            or size < 1
            or not isinstance(sha256, str)
            or len(sha256) != 64
            or any(character not in "0123456789abcdef" for character in sha256)
        ):
            raise InventoryError(f"{manifest_path}: invalid size or SHA-256 for {name}")
        matching = artifact
    return {
        "artifact": matching,
        "branch": branch,
        "branchProvenance": "caller-asserted",
        "buildId": build_id,
        "target": target,
    }


def _zip_entry_count(stream: BinaryIO, source: Path) -> int:
    """Count central-directory records before ZipFile materializes them."""
    try:
        original_position = stream.tell()
        stream.seek(0, os.SEEK_END)
        source_size = stream.tell()
        tail_size = min(source_size, 22 + 0xFFFF + 20 + 56)
        stream.seek(source_size - tail_size)
        tail = stream.read(tail_size)
    except OSError as error:
        raise InventoryError(f"{source}: could not inspect zip directory bounds") from error
    finally:
        try:
            stream.seek(original_position)
        except (OSError, UnboundLocalError):
            pass

    end_signature = b"PK\x05\x06"
    offset = len(tail)
    end_record_offset = -1
    total_entries = -1
    while True:
        offset = tail.rfind(end_signature, 0, offset)
        if offset < 0:
            break
        if offset + 22 <= len(tail):
            comment_size = struct.unpack_from("<H", tail, offset + 20)[0]
            if offset + 22 + comment_size == len(tail):
                end_record_offset = offset
                total_entries = struct.unpack_from("<H", tail, offset + 10)[0]
                break
        if offset == 0:
            break
    if end_record_offset < 0:
        raise InventoryError(f"{source}: zip archive has no valid end-of-directory record")
    absolute_end_record = source_size - tail_size + end_record_offset
    (
        _signature,
        disk_number,
        directory_disk,
        entries_on_disk,
        total_entries,
        directory_size,
        directory_offset,
        _comment_size,
    ) = struct.unpack_from("<4s4H2IH", tail, end_record_offset)
    directory_end = absolute_end_record

    zip64_sentinels = (
        entries_on_disk == 0xFFFF
        or total_entries == 0xFFFF
        or directory_size == 0xFFFFFFFF
        or directory_offset == 0xFFFFFFFF
    )
    if zip64_sentinels:
        locator_offset = absolute_end_record - 20
        if locator_offset < 0:
            raise InventoryError(f"{source}: zip64 archive has no locator")
        try:
            stream.seek(locator_offset)
            locator = stream.read(20)
            if len(locator) != 20:
                raise InventoryError(f"{source}: zip64 locator is truncated")
            locator_signature, locator_disk, zip64_offset, disk_count = struct.unpack(
                "<4sIQI", locator
            )
            if locator_signature != b"PK\x06\x07" or locator_disk != 0 or disk_count != 1:
                raise InventoryError(f"{source}: zip64 archive has no valid single-disk locator")
            if zip64_offset > source_size - 56:
                raise InventoryError(f"{source}: zip64 directory record is out of bounds")
        except OSError as error:
            raise InventoryError(f"{source}: could not inspect zip64 directory bounds") from error

        zip64_record_offset = -1
        zip64_record = b""
        search_start = max(0, locator_offset - MAX_ZIP64_RECORD_SIZE - 12)
        try:
            stream.seek(search_start)
            search_region = stream.read(locator_offset - search_start)
        except OSError as error:
            raise InventoryError(f"{source}: could not inspect zip64 directory bounds") from error
        signature_offset = len(search_region)
        while True:
            signature_offset = search_region.rfind(b"PK\x06\x06", 0, signature_offset)
            if signature_offset < 0:
                break
            absolute_offset = search_start + signature_offset
            if signature_offset + 12 <= len(search_region):
                record_size = struct.unpack_from("<Q", search_region, signature_offset + 4)[0]
                if (
                    44 <= record_size <= MAX_ZIP64_RECORD_SIZE
                    and absolute_offset + 12 + record_size == locator_offset
                ):
                    zip64_record_offset = absolute_offset
                    zip64_record = search_region[signature_offset : signature_offset + 56]
                    break
            if signature_offset == 0:
                break

        if len(zip64_record) != 56:
            raise InventoryError(f"{source}: zip64 directory record is truncated")
        (
            zip64_signature,
            record_size,
            _version_made,
            _version_needed,
            zip64_disk_number,
            zip64_directory_disk,
            entries_on_disk,
            total_entries,
            directory_size,
            directory_offset,
        ) = struct.unpack("<4sQ2H2I4Q", zip64_record)
        if (
            zip64_signature != b"PK\x06\x06"
            or record_size != 44
            or zip64_record_offset + 12 + record_size != locator_offset
        ):
            raise InventoryError(
                f"{source}: zip64 end records with extensible data are unsupported"
            )
        if zip64_disk_number != 0 or zip64_directory_disk != 0:
            raise InventoryError(f"{source}: multi-disk zip archives are unsupported")
        directory_end = zip64_record_offset
    elif disk_number != 0 or directory_disk != 0:
        raise InventoryError(f"{source}: multi-disk zip archives are unsupported")

    if entries_on_disk != total_entries:
        raise InventoryError(f"{source}: multi-disk zip archives are unsupported")
    if directory_size > MAX_CENTRAL_DIRECTORY_SIZE:
        raise InventoryError(
            f"{source}: zip central directory exceeds the {MAX_CENTRAL_DIRECTORY_SIZE}-byte limit"
        )
    directory_start = directory_end - directory_size
    if directory_start < 0 or directory_offset > directory_start:
        raise InventoryError(f"{source}: zip central-directory bounds are invalid")

    actual_entries = 0
    cursor = directory_start
    while cursor < directory_end:
        try:
            stream.seek(cursor)
            header = stream.read(46)
        except OSError as error:
            raise InventoryError(f"{source}: could not inspect zip central directory") from error
        if len(header) < 6:
            raise InventoryError(f"{source}: zip central-directory record is truncated")
        signature = header[:4]
        if signature == b"PK\x05\x05":
            signature_size = struct.unpack_from("<H", header, 4)[0]
            if cursor + 6 + signature_size != directory_end:
                raise InventoryError(f"{source}: zip central-directory signature is invalid")
            cursor = directory_end
            break
        if len(header) != 46 or signature != b"PK\x01\x02":
            raise InventoryError(f"{source}: zip central-directory record is invalid")
        name_size, extra_size, comment_size = struct.unpack_from("<HHH", header, 28)
        next_cursor = cursor + 46 + name_size + extra_size + comment_size
        if next_cursor > directory_end:
            raise InventoryError(f"{source}: zip central-directory record is out of bounds")
        actual_entries += 1
        if actual_entries > MAX_ARCHIVE_ENTRIES:
            stream.seek(original_position)
            return actual_entries
        cursor = next_cursor

    if cursor != directory_end or actual_entries != total_entries:
        raise InventoryError(
            f"{source}: zip central-directory entry count does not match its end record"
        )
    stream.seek(original_position)
    return actual_entries


def _inventory_archive(
    source: Path,
    fetch_context: dict[str, object] | None,
) -> dict[str, object]:
    """Inventory one stable archive and attach matching fetch provenance."""
    try:
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise InventoryError(f"{source}: could not safely open zip archive: {error}") from error
    with os.fdopen(descriptor, "rb") as stream:
        initial_stat = os.fstat(descriptor)
        if not stat.S_ISREG(initial_stat.st_mode):
            raise InventoryError(f"{source}: zip archive must be a regular file")
        archive_size = initial_stat.st_size
        if archive_size > MAX_ARCHIVE_SIZE:
            raise InventoryError(
                f"{source}: zip archive exceeds the {MAX_ARCHIVE_SIZE}-byte input limit"
            )
        entry_count = _zip_entry_count(stream, source)
        if entry_count > MAX_ARCHIVE_ENTRIES:
            raise InventoryError(
                f"{source}: zip archive exceeds the {MAX_ARCHIVE_ENTRIES}-entry limit"
            )
        archive_sha256 = _hash_stream(stream, archive_size, str(source))
        source_info: dict[str, object] = {
            "name": source.name,
            "sha256": archive_sha256,
            "size": archive_size,
            "type": "zip",
        }
        if fetch_context is not None:
            artifact = fetch_context["artifact"]
            if not isinstance(artifact, dict):
                raise InventoryError("fetch metadata contains an invalid artifact record")
            if artifact.get("size") != archive_size or artifact.get("sha256") != archive_sha256:
                raise InventoryError(
                    f"{source.name}: archive size or SHA-256 does not match fetch.json"
                )
            source_info.update(
                {
                    "branch": fetch_context["branch"],
                    "branchProvenance": fetch_context["branchProvenance"],
                    "buildId": fetch_context["buildId"],
                    "target": fetch_context["target"],
                }
            )
        try:
            with zipfile.ZipFile(stream, "r") as archive:
                entries = _zip_entries(archive)
                files = [_inventory_file(entry) for entry in entries]
        except (OSError, zipfile.BadZipFile) as error:
            raise InventoryError(f"{source}: could not read zip archive: {error}") from error
        final_stat = os.fstat(descriptor)
        try:
            path_stat = source.lstat()
        except OSError as error:
            raise InventoryError(f"{source}: archive path changed during inventory") from error
        if (
            not stat.S_ISREG(path_stat.st_mode)
            or _file_version(final_stat) != _file_version(initial_stat)
            or _file_version(path_stat) != _file_version(final_stat)
        ):
            raise InventoryError(f"{source}: archive changed during inventory")
    return {
        "files": files,
        "generator": f"apkrun_image.inventory {__version__}",
        "schemaVersion": 2,
        "source": source_info,
    }


def inventory(source_path: Path) -> dict[str, object]:
    """Build a deterministic inventory from a zip archive or unpacked directory."""
    source = source_path.expanduser()
    if source.is_symlink():
        raise InventoryError(f"{source}: input must not be a symbolic link")
    if source.is_dir():
        fetch_context = _fetch_context(source)
        if fetch_context is not None:
            artifact = fetch_context["artifact"]
            if not isinstance(artifact, dict) or not isinstance(artifact.get("name"), str):
                raise InventoryError("fetch.json contains an invalid artifact name")
            archive_path = source / artifact["name"]
            if archive_path.is_symlink() or not archive_path.is_file():
                raise InventoryError(
                    f"{archive_path}: downloaded archive is missing or not a regular file"
                )
            if not zipfile.is_zipfile(archive_path):
                raise InventoryError(
                    f"{archive_path}: fetch metadata does not identify a zip archive"
                )
            return _inventory_archive(archive_path, fetch_context)
        entries = _directory_entries(source)
        source_info: dict[str, object] = {
            "name": source.name,
            "type": "directory",
        }
    elif source.is_file() and zipfile.is_zipfile(source):
        return _inventory_archive(
            source,
            _fetch_context(source.parent, expected_name=source.name),
        )
    else:
        raise InventoryError(f"{source} is neither a directory nor a readable zip archive.")

    files = [_inventory_file(entry) for entry in entries]
    return {
        "files": files,
        "generator": f"apkrun_image.inventory {__version__}",
        "schemaVersion": 2,
        "source": source_info,
    }


def serialize_inventory(value: Mapping[str, object]) -> str:
    """Serialize inventory JSON in its deterministic committed form."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n"


def _write_inventory(path: Path, content: str) -> None:
    """Atomically write JSON without following an output-path symlink."""
    if path.is_symlink():
        raise InventoryError(f"inventory output must not be a symbolic link: {path}")
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".partial",
            delete=False,
        ) as output:
            temporary_path = Path(output.name)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
    except OSError as error:
        raise InventoryError(f"could not safely write inventory output {path}: {error}") from error
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def build_parser() -> argparse.ArgumentParser:
    """Build the inventory command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image inventory",
        description="Inventory every file in an Android build by content.",
    )
    parser.add_argument("source", type=Path, help="zip archive or unpacked directory")
    parser.add_argument("--out", type=Path, help="write JSON to this path instead of stdout")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point used by both the package and repository script."""
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        result = inventory(arguments.source)
        output = serialize_inventory(result)
        if arguments.out is None:
            sys.stdout.write(output)
        else:
            output_path = arguments.out.expanduser()
            source_path = arguments.source.expanduser()
            resolved_output = output_path.resolve()
            resolved_source = source_path.resolve()
            if source_path.is_dir() and resolved_output.is_relative_to(resolved_source):
                raise InventoryError("inventory output must be outside the input directory")
            if source_path.is_file() and resolved_output == resolved_source:
                raise InventoryError("inventory output must not replace the input archive")
            output_path.parent.mkdir(parents=True, exist_ok=True)
            _write_inventory(output_path, output)
    except (InventoryError, LpMetadataError, SparseImageError, OSError) as error:
        print(
            f"apkrun_image inventory: {error} "
            "Check the archive and re-run fetch before retrying inventory.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
