"""Read-only parser for Android liblp dynamic-partition metadata."""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass
from typing import BinaryIO

from apkrun_image.sparse import read_range as read_sparse_range

LP_GEOMETRY_MAGIC = 0x616C4467
LP_METADATA_MAGIC = 0x414C5030
GEOMETRY_OFFSET = 4096
GEOMETRY_SIZE = 4096
METADATA_START = GEOMETRY_OFFSET + 2 * GEOMETRY_SIZE
GEOMETRY_STRUCT_SIZE = 52
METADATA_HEADER_SIZE = 128
SECTOR_SIZE = 512
PARTITION_ENTRY_SIZE = 52
EXTENT_ENTRY_SIZE = 24
GROUP_ENTRY_SIZE = 48
BLOCK_DEVICE_ENTRY_SIZE = 64
MAX_METADATA_SIZE = 16 * 1024 * 1024


class LpMetadataError(ValueError):
    """A malformed or unsupported liblp metadata region."""


@dataclass(frozen=True)
class Geometry:
    """Parsed liblp geometry."""

    metadata_max_size: int
    metadata_slot_count: int
    logical_block_size: int


@dataclass(frozen=True)
class LogicalPartition:
    """A logical partition and its group."""

    name: str
    size: int
    group: str


@dataclass(frozen=True)
class Metadata:
    """Inventory details recovered from one liblp metadata slot."""

    logical_partitions: tuple[LogicalPartition, ...]
    block_device_size: int
    metadata_slots: int

    def as_dict(self) -> dict[str, object]:
        """Return the stable inventory representation."""
        return {
            "blockDeviceSize": self.block_device_size,
            "logicalPartitions": [
                {"group": item.group, "name": item.name, "size": item.size}
                for item in self.logical_partitions
            ],
            "metadataSlots": self.metadata_slots,
        }


def _sha256_matches(data: bytes, checksum_offset: int, expected: bytes) -> bool:
    """Check a SHA-256 field after replacing it with zero bytes."""
    if checksum_offset < 0 or checksum_offset + len(expected) > len(data):
        return False
    calculated_data = (
        data[:checksum_offset] + b"\0" * len(expected) + data[checksum_offset + len(expected) :]
    )
    return hashlib.sha256(calculated_data).digest() == expected


def _decode_name(value: bytes, context: str) -> str:
    """Decode a fixed-width UTF-8 metadata name."""
    raw_name = value.split(b"\0", 1)[0]
    if not raw_name:
        raise LpMetadataError(f"{context} has an empty name")
    try:
        name = raw_name.decode("utf-8")
    except UnicodeDecodeError as error:
        raise LpMetadataError(f"{context} has a non-UTF-8 name") from error
    if "/" in name or name in {".", ".."}:
        raise LpMetadataError(f"{context} has an invalid name")
    return name


def parse_geometry(data: bytes) -> Geometry:
    """Parse and validate one 4096-byte liblp geometry block."""
    if len(data) < GEOMETRY_STRUCT_SIZE:
        raise LpMetadataError("truncated liblp geometry")
    magic, struct_size = struct.unpack_from("<II", data)
    if magic != LP_GEOMETRY_MAGIC:
        raise LpMetadataError("invalid liblp geometry magic")
    if struct_size < GEOMETRY_STRUCT_SIZE or struct_size > GEOMETRY_SIZE:
        raise LpMetadataError(f"unsupported liblp geometry structure size {struct_size}")
    expected_checksum = data[8:40]
    if not _sha256_matches(data[:struct_size], 8, expected_checksum):
        raise LpMetadataError("liblp geometry checksum mismatch")
    metadata_max_size, metadata_slot_count, logical_block_size = struct.unpack_from(
        "<III", data, 40
    )
    if metadata_max_size < METADATA_HEADER_SIZE:
        raise LpMetadataError("liblp metadata maximum size is too small")
    if metadata_max_size > MAX_METADATA_SIZE:
        raise LpMetadataError(
            f"liblp metadata maximum size {metadata_max_size} exceeds the parser limit"
        )
    if metadata_slot_count < 1 or metadata_slot_count > 8:
        raise LpMetadataError(f"unsupported liblp metadata slot count {metadata_slot_count}")
    if logical_block_size < SECTOR_SIZE or logical_block_size & (logical_block_size - 1):
        raise LpMetadataError(f"invalid liblp logical block size {logical_block_size}")
    return Geometry(
        metadata_max_size=metadata_max_size,
        metadata_slot_count=metadata_slot_count,
        logical_block_size=logical_block_size,
    )


def _table_descriptor(header: bytes, offset: int) -> tuple[int, int, int]:
    """Read and validate one metadata table descriptor."""
    return struct.unpack_from("<III", header, offset)


def _validate_table(
    *,
    name: str,
    descriptor: tuple[int, int, int],
    minimum_entry_size: int,
    tables_size: int,
) -> tuple[int, int, int]:
    """Check a descriptor's entry layout and table bounds."""
    offset, count, entry_size = descriptor
    if count == 0:
        if offset > tables_size:
            raise LpMetadataError(f"liblp {name} table starts past the table data")
        return descriptor
    if entry_size < minimum_entry_size:
        raise LpMetadataError(f"liblp {name} entries are too small")
    if offset > tables_size or count > (tables_size - offset) // entry_size:
        raise LpMetadataError(f"liblp {name} table extends past the table data")
    return descriptor


def parse_metadata(data: bytes, geometry: Geometry) -> Metadata:
    """Parse slot-zero liblp metadata and its referenced tables."""
    if len(data) < METADATA_HEADER_SIZE:
        raise LpMetadataError("truncated liblp metadata header")
    magic, major_version, _minor_version, header_size = struct.unpack_from("<IHHI", data)
    if magic != LP_METADATA_MAGIC:
        raise LpMetadataError("invalid liblp metadata magic")
    if major_version != 10:
        raise LpMetadataError(f"unsupported liblp metadata major version {major_version}")
    if header_size < METADATA_HEADER_SIZE or header_size > geometry.metadata_max_size:
        raise LpMetadataError(f"invalid liblp metadata header size {header_size}")
    if len(data) < header_size:
        raise LpMetadataError("truncated liblp metadata header")
    header = data[:header_size]
    if not _sha256_matches(header, 12, header[12:44]):
        raise LpMetadataError("liblp metadata header checksum mismatch")
    tables_size = struct.unpack_from("<I", header, 44)[0]
    expected_tables_checksum = header[48:80]
    if tables_size > geometry.metadata_max_size - header_size:
        raise LpMetadataError("liblp metadata tables exceed the configured maximum size")
    if len(data) < header_size + tables_size:
        raise LpMetadataError("truncated liblp metadata tables")
    tables = data[header_size : header_size + tables_size]
    if hashlib.sha256(tables).digest() != expected_tables_checksum:
        raise LpMetadataError("liblp metadata tables checksum mismatch")

    partitions = _validate_table(
        name="partition",
        descriptor=_table_descriptor(header, 80),
        minimum_entry_size=PARTITION_ENTRY_SIZE,
        tables_size=tables_size,
    )
    extents = _validate_table(
        name="extent",
        descriptor=_table_descriptor(header, 92),
        minimum_entry_size=EXTENT_ENTRY_SIZE,
        tables_size=tables_size,
    )
    groups = _validate_table(
        name="group",
        descriptor=_table_descriptor(header, 104),
        minimum_entry_size=GROUP_ENTRY_SIZE,
        tables_size=tables_size,
    )
    block_devices = _validate_table(
        name="block device",
        descriptor=_table_descriptor(header, 116),
        minimum_entry_size=BLOCK_DEVICE_ENTRY_SIZE,
        tables_size=tables_size,
    )

    group_names: list[str] = []
    group_offset, group_count, group_entry_size = groups
    for index in range(group_count):
        entry_offset = group_offset + index * group_entry_size
        group_names.append(
            _decode_name(tables[entry_offset : entry_offset + 36], f"liblp group {index}")
        )

    device_offset, device_count, device_entry_size = block_devices
    if device_count < 1:
        raise LpMetadataError("liblp metadata has no block device")
    device_sizes: list[int] = []
    for index in range(device_count):
        entry_offset = device_offset + index * device_entry_size
        device_size = struct.unpack_from("<Q", tables, entry_offset + 16)[0]
        if device_size == 0:
            raise LpMetadataError(f"liblp block device {index} has a zero size")
        device_sizes.append(device_size)

    extent_sizes: list[int] = []
    extent_offset, extent_count, extent_entry_size = extents
    for index in range(extent_count):
        entry_offset = extent_offset + index * extent_entry_size
        sector_count, target_type, target_data, target_source = struct.unpack_from(
            "<QIQI", tables, entry_offset
        )
        if target_type == 0:
            if target_source >= len(device_sizes):
                raise LpMetadataError(f"liblp linear extent {index} references a missing device")
            device_sectors = device_sizes[target_source] // SECTOR_SIZE
            if target_data > device_sectors or sector_count > device_sectors - target_data:
                raise LpMetadataError(
                    f"liblp linear extent {index} extends past its backing device"
                )
        elif target_type != 1:
            raise LpMetadataError(f"liblp extent {index} has unsupported target type {target_type}")
        extent_sizes.append(sector_count * SECTOR_SIZE)

    logical_partitions: list[LogicalPartition] = []
    partition_names: set[str] = set()
    partition_offset, partition_count, partition_entry_size = partitions
    for index in range(partition_count):
        entry_offset = partition_offset + index * partition_entry_size
        name = _decode_name(
            tables[entry_offset : entry_offset + 36],
            f"liblp partition {index}",
        )
        if name in partition_names:
            raise LpMetadataError(f"duplicate liblp partition name {name!r}")
        partition_names.add(name)
        _attributes, first_extent, extent_count, group_index = struct.unpack_from(
            "<IIII", tables, entry_offset + 36
        )
        if first_extent > len(extent_sizes) or extent_count > len(extent_sizes) - first_extent:
            raise LpMetadataError(f"liblp partition {name!r} references missing extents")
        if group_index >= len(group_names):
            raise LpMetadataError(f"liblp partition {name!r} references a missing group")
        size = sum(extent_sizes[first_extent : first_extent + extent_count])
        logical_partitions.append(
            LogicalPartition(name=name, size=size, group=group_names[group_index])
        )

    first_device = tables[device_offset : device_offset + device_entry_size]
    block_device_size = struct.unpack_from("<Q", first_device, 16)[0]

    logical_partitions.sort(key=lambda item: item.name)
    return Metadata(
        logical_partitions=tuple(logical_partitions),
        block_device_size=block_device_size,
        metadata_slots=geometry.metadata_slot_count,
    )


def read_dynamic_partitions(stream: BinaryIO, *, sparse: bool = False) -> Metadata | None:
    """Read the first valid geometry and slot-zero metadata from a raw or sparse image."""

    def read_at(offset: int, size: int) -> bytes:
        if sparse:
            return read_sparse_range(stream, offset, size)
        stream.seek(offset)
        return stream.read(size)

    geometry_data = read_at(GEOMETRY_OFFSET, GEOMETRY_SIZE)
    if len(geometry_data) < 4 or struct.unpack_from("<I", geometry_data)[0] != LP_GEOMETRY_MAGIC:
        return None
    geometry = parse_geometry(geometry_data)
    if sparse:
        from apkrun_image.sparse import read_header

        image_size = read_header(stream).logical_size
    else:
        try:
            current_position = stream.tell()
            stream.seek(0, 2)
            image_size = stream.tell()
            stream.seek(current_position)
        except (OSError, AttributeError) as error:
            raise LpMetadataError("liblp image input must be seekable") from error
    if METADATA_START > image_size or geometry.metadata_max_size > image_size - METADATA_START:
        raise LpMetadataError("liblp metadata region extends past the image")
    metadata_data = read_at(METADATA_START, geometry.metadata_max_size)
    metadata = parse_metadata(metadata_data, geometry)
    if metadata.block_device_size > image_size:
        raise LpMetadataError("liblp block device size exceeds the image")
    return metadata
