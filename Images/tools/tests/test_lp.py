"""Tests for read-only liblp geometry and metadata parsing."""

from __future__ import annotations

import hashlib
import io
import struct

import pytest

from apkrun_image.lp import (
    GEOMETRY_OFFSET,
    GEOMETRY_SIZE,
    LP_GEOMETRY_MAGIC,
    LP_METADATA_MAGIC,
    METADATA_HEADER_SIZE,
    METADATA_START,
    LpMetadataError,
    read_dynamic_partitions,
)
from apkrun_image.sparse import CHUNK_RAW, SPARSE_MAGIC


def build_geometry(metadata_max_size: int, slot_count: int = 2) -> bytes:
    """Create one checksummed liblp geometry block."""
    geometry = bytearray(GEOMETRY_SIZE)
    struct.pack_into("<II", geometry, 0, LP_GEOMETRY_MAGIC, 52)
    struct.pack_into("<III", geometry, 40, metadata_max_size, slot_count, 4096)
    geometry[8:40] = hashlib.sha256(geometry[:52]).digest()
    return bytes(geometry)


def build_metadata(
    block_device_size: int = 2 * 1024 * 1024,
    first_extent_target_data: int = 2048,
    first_extent_target_source: int = 0,
) -> bytes:
    """Create one checksummed metadata slot with two logical partitions."""
    groups = struct.pack("<36sIQ", b"google_dynamic_partitions_a", 0, 0)
    extents = struct.pack(
        "<QIQI",
        2048,
        0,
        first_extent_target_data,
        first_extent_target_source,
    ) + struct.pack("<QIQI", 1024, 0, 2048, 0)
    partitions = struct.pack("<36sIIII", b"system_a", 0, 0, 1, 0) + struct.pack(
        "<36sIIII", b"vendor_a", 0, 1, 1, 0
    )
    device = struct.pack("<QIIQ36sI", 0, 0, 0, block_device_size, b"super", 0)
    tables = partitions + extents + groups + device
    header = bytearray(METADATA_HEADER_SIZE)
    struct.pack_into("<IHHI", header, 0, LP_METADATA_MAGIC, 10, 2, METADATA_HEADER_SIZE)
    struct.pack_into("<I", header, 44, len(tables))
    header[48:80] = hashlib.sha256(tables).digest()
    descriptors = [
        (0, 2, 52),
        (len(partitions), 2, 24),
        (len(partitions) + len(extents), 1, 48),
        (len(partitions) + len(extents) + len(groups), 1, 64),
    ]
    for index, descriptor in enumerate(descriptors):
        struct.pack_into("<III", header, 80 + index * 12, *descriptor)
    header[12:44] = hashlib.sha256(header).digest()
    return bytes(header) + tables


def raw_super_fixture(
    block_device_size: int = 2 * 1024 * 1024,
    first_extent_target_data: int = 2048,
    first_extent_target_source: int = 0,
) -> bytes:
    """Place a valid geometry pair and slot-zero metadata in a raw super image."""
    geometry = build_geometry(4096, 2)
    metadata = build_metadata(
        block_device_size,
        first_extent_target_data,
        first_extent_target_source,
    )
    image = bytearray(2 * 1024 * 1024)
    image[GEOMETRY_OFFSET : GEOMETRY_OFFSET + GEOMETRY_SIZE] = geometry
    image[GEOMETRY_OFFSET + GEOMETRY_SIZE : METADATA_START] = geometry
    image[METADATA_START : METADATA_START + len(metadata)] = metadata
    return bytes(image)


def sparse_raw_image(raw: bytes) -> bytes:
    """Wrap the synthetic super image in a single raw sparse chunk."""
    chunk = struct.pack("<HHII", CHUNK_RAW, 0, len(raw) // 4096, 12 + len(raw)) + raw
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        4096,
        len(raw) // 4096,
        1,
        0,
    )
    return header + chunk


def test_reads_dynamic_partitions_from_raw_image() -> None:
    """Partition names, sizes, groups, slots, and device size are recovered."""
    metadata = read_dynamic_partitions(io.BytesIO(raw_super_fixture()))

    assert metadata is not None
    assert metadata.as_dict() == {
        "blockDeviceSize": 2 * 1024 * 1024,
        "logicalPartitions": [
            {"group": "google_dynamic_partitions_a", "name": "system_a", "size": 1_048_576},
            {"group": "google_dynamic_partitions_a", "name": "vendor_a", "size": 524_288},
        ],
        "metadataSlots": 2,
    }


def test_reads_dynamic_partitions_from_sparse_image() -> None:
    """Sparse super metadata is read from its expanded logical offsets."""
    metadata = read_dynamic_partitions(
        io.BytesIO(sparse_raw_image(raw_super_fixture())),
        sparse=True,
    )

    assert metadata is not None
    assert [partition.name for partition in metadata.logical_partitions] == ["system_a", "vendor_a"]


def test_non_liblp_image_returns_none() -> None:
    """Images without the geometry magic are not treated as super metadata."""
    assert read_dynamic_partitions(io.BytesIO(b"\0" * 8192)) is None


def test_geometry_checksum_mismatch_is_rejected() -> None:
    """A corrupt geometry checksum is not silently accepted."""
    image = bytearray(raw_super_fixture())
    image[GEOMETRY_OFFSET + 8] ^= 0x01

    with pytest.raises(LpMetadataError, match="geometry checksum"):
        read_dynamic_partitions(io.BytesIO(image))


def test_metadata_tables_checksum_mismatch_is_rejected() -> None:
    """Corrupt partition tables fail before producing inventory details."""
    image = bytearray(raw_super_fixture())
    image[METADATA_START + METADATA_HEADER_SIZE + 10] ^= 0x01

    with pytest.raises(LpMetadataError, match="tables checksum"):
        read_dynamic_partitions(io.BytesIO(image))


def test_oversized_metadata_maximum_is_rejected_before_reading() -> None:
    """A crafted geometry cannot request an unbounded metadata allocation."""
    image = bytearray(raw_super_fixture())
    oversized = build_geometry(0xFFFFFFFF)
    image[GEOMETRY_OFFSET : GEOMETRY_OFFSET + GEOMETRY_SIZE] = oversized

    with pytest.raises(LpMetadataError, match="exceeds the parser limit"):
        read_dynamic_partitions(io.BytesIO(image))


def test_block_device_larger_than_image_is_rejected() -> None:
    """Metadata cannot claim a backing device beyond its containing image."""
    image = raw_super_fixture(block_device_size=7_516_192_768)

    with pytest.raises(LpMetadataError, match="block device size exceeds the image"):
        read_dynamic_partitions(io.BytesIO(image))


def test_linear_extent_beyond_backing_device_is_rejected() -> None:
    """A linear extent must fit its referenced physical block device."""
    image = raw_super_fixture(first_extent_target_data=4095)

    with pytest.raises(LpMetadataError, match="extends past its backing device"):
        read_dynamic_partitions(io.BytesIO(image))


def test_linear_extent_missing_device_is_rejected() -> None:
    """A linear extent cannot refer to a device index outside the table."""
    image = raw_super_fixture(first_extent_target_source=1)

    with pytest.raises(LpMetadataError, match="references a missing device"):
        read_dynamic_partitions(io.BytesIO(image))
