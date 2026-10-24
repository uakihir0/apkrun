"""Tests for growing a sparse liblp partition while preserving its active metadata."""

from __future__ import annotations

import hashlib
import struct
from collections.abc import Callable
from pathlib import Path

import pytest
import test_lp_write
from test_lp_write import (
    DEVICE_SIZE,
    GROUPS,
    KIB,
    METADATA_MAX,
    MIB,
    SLOT_COUNT,
    build_geometry,
    encode_sparse,
    expanded,
    make_content,
    make_super,
)

from apkrun_image import lp, sparse
from apkrun_image.lp_grow import (
    GroupSizeExceededError,
    LpGrowError,
    grow_partition,
    partition_growth_limit,
)


def _refresh_metadata_checksum(metadata: bytearray) -> None:
    header_size = struct.unpack_from("<I", metadata, 8)[0]
    tables_size = struct.unpack_from("<I", metadata, 44)[0]
    tables = metadata[header_size : header_size + tables_size]
    metadata[48:80] = hashlib.sha256(tables).digest()
    metadata[12:44] = bytes(32)
    metadata[12:44] = hashlib.sha256(metadata[:header_size]).digest()


def _update_active_metadata(logical: bytearray, edit: Callable[[bytearray], None]) -> None:
    """Apply one metadata-table edit to all active primary and backup copies."""
    for slot in range(SLOT_COUNT):
        for base in (
            lp.METADATA_START,
            lp.METADATA_START + SLOT_COUNT * METADATA_MAX,
        ):
            offset = base + slot * METADATA_MAX
            metadata = bytearray(logical[offset : offset + METADATA_MAX])
            if not any(metadata):
                continue
            edit(metadata)
            _refresh_metadata_checksum(metadata)
            logical[offset : offset + METADATA_MAX] = metadata


def _set_group_maximum(logical: bytearray, group_name: str, maximum_size: int) -> None:
    def edit(metadata: bytearray) -> None:
        header_size = struct.unpack_from("<I", metadata, 8)[0]
        tables_size = struct.unpack_from("<I", metadata, 44)[0]
        tables = memoryview(metadata)[header_size : header_size + tables_size]
        offset, count, entry_size = struct.unpack_from("<III", metadata, 104)
        for index in range(count):
            start = offset + index * entry_size
            name = bytes(tables[start : start + 36]).split(b"\0", 1)[0].decode()
            if name == group_name:
                struct.pack_into("<Q", tables, start + 40, maximum_size)
                return
        raise AssertionError(f"missing group {group_name}")

    _update_active_metadata(logical, edit)


def _set_block_device_size(logical: bytearray, size: int) -> None:
    def edit(metadata: bytearray) -> None:
        header_size = struct.unpack_from("<I", metadata, 8)[0]
        tables_size = struct.unpack_from("<I", metadata, 44)[0]
        tables = memoryview(metadata)[header_size : header_size + tables_size]
        offset, count, entry_size = struct.unpack_from("<III", metadata, 116)
        assert count == 1
        struct.pack_into("<Q", tables, offset + 16, size)

    _update_active_metadata(logical, edit)


def _set_block_device_alignment_offset(logical: bytearray, offset: int) -> None:
    def edit(metadata: bytearray) -> None:
        header_size = struct.unpack_from("<I", metadata, 8)[0]
        tables_size = struct.unpack_from("<I", metadata, 44)[0]
        tables = memoryview(metadata)[header_size : header_size + tables_size]
        table_offset, count, _entry_size = struct.unpack_from("<III", metadata, 116)
        assert count == 1
        struct.pack_into("<I", tables, table_offset + 12, offset)

    _update_active_metadata(logical, edit)


def _write_sparse(tmp_path: Path, name: str, logical: bytearray) -> Path:
    path = tmp_path / name
    path.write_bytes(encode_sparse(bytes(logical), max_run=5))
    return path


def test_grows_partition_and_updates_all_metadata_copies(tmp_path: Path) -> None:
    """Growth adds only free extents, zeroes them, and preserves unrelated partitions."""
    source, logical = make_super(tmp_path)
    destination = tmp_path / "grown.img"

    result = grow_partition(source, "system_a", 2 * MIB, destination)

    assert result.previous_size == MIB
    assert result.partition_size == 2 * MIB
    assert result.metadata_copies_updated == 2 * SLOT_COUNT
    assert result.allocated_extents
    assert all(
        extent.target_type == 0 and extent.target_source == 0 for extent in result.allocated_extents
    )
    assert all(
        extent.target_data * lp.SECTOR_SIZE % MIB == 0 for extent in result.allocated_extents
    )
    with destination.open("rb") as stream:
        metadata = lp.read_dynamic_partitions(stream, sparse=True)
        assert metadata is not None
        system = next(item for item in metadata.logical_partitions if item.name == "system_a")
        assert system.size == 2 * MIB
        assert lp.read_partition_range(stream, system, MIB, MIB, sparse=True) == bytes(MIB)
        assert test_lp_write.check_copies(stream) == 2 + 2 * SLOT_COUNT
    assert result.other_partitions_verified == len(GROUPS)
    assert not list(tmp_path.glob(".grown.img.partial"))
    assert expanded(source) == logical


def test_group_maximum_is_enforced_before_output_is_created(tmp_path: Path) -> None:
    """The requested growth must fit the declared liblp group maximum."""
    _original, logical = make_super(tmp_path)
    logical = bytearray(logical)
    _set_group_maximum(logical, "google_system_dynamic_partitions_a", 2 * MIB)
    source = _write_sparse(tmp_path, "capped.img", logical)
    destination = tmp_path / "capped-grown.img"

    with pytest.raises(GroupSizeExceededError, match="maximum size"):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".capped-grown.img.partial"))


def test_growth_limit_accounts_for_group_capacity_and_free_extents(tmp_path: Path) -> None:
    """The composer can bound AVB sizing without guessing from the super's total size."""
    _original, logical = make_super(tmp_path)
    logical = bytearray(logical)
    _set_group_maximum(logical, "google_system_dynamic_partitions_a", 3 * MIB)
    source = _write_sparse(tmp_path, "growth-limit.img", logical)

    assert partition_growth_limit(source, "system_a") == 11 * MIB // 4

    logical = bytearray(logical)
    _set_group_maximum(logical, "google_system_dynamic_partitions_a", 0)
    _set_block_device_size(logical, 5 * MIB)
    source = _write_sparse(tmp_path, "device-growth-limit.img", logical)
    # The declared device ends at 5 MiB, but liblp extents and 1 MiB alignment leave
    # only 512 KiB allocatable after system_a's existing 1 MiB extent.
    assert partition_growth_limit(source, "system_a") == 3 * MIB // 2


def test_growth_limit_rejects_missing_and_non_sparse_partitions(tmp_path: Path) -> None:
    source, _logical = make_super(tmp_path)
    with pytest.raises(LpGrowError, match="no such logical partition"):
        partition_growth_limit(source, "missing_a")

    raw = tmp_path / "raw.img"
    raw.write_bytes(bytes(4096))
    with pytest.raises(LpGrowError, match="sparse super"):
        partition_growth_limit(raw, "system_a")


def test_block_device_size_bounds_extent_allocation(tmp_path: Path) -> None:
    """Free bytes beyond the liblp block-device limit are not allocated."""
    _original, logical = make_super(tmp_path)
    logical = bytearray(logical)
    _set_block_device_size(logical, 5 * MIB)
    source = _write_sparse(tmp_path, "bounded.img", logical)
    destination = tmp_path / "bounded-grown.img"

    with pytest.raises(LpGrowError, match="could not allocate"):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert not destination.exists()


def test_sparse_and_block_device_alignment_are_combined(tmp_path: Path) -> None:
    """Allocated extents satisfy both sparse block and liblp device alignment."""
    _original, logical = make_super(tmp_path)
    logical = bytearray(logical)
    _set_block_device_alignment_offset(logical, 4 * KIB)
    source = _write_sparse(tmp_path, "aligned.img", logical)

    result = grow_partition(source, "system_a", 2 * MIB, tmp_path / "aligned-grown.img")

    start = result.allocated_extents[0].target_data * lp.SECTOR_SIZE
    assert start % (4 * KIB) == 0
    assert start % MIB == 4 * KIB


def test_incompatible_sparse_alignment_offset_is_refused(tmp_path: Path) -> None:
    """An alignment offset with no sparse-block congruence is rejected."""
    _original, logical = make_super(tmp_path)
    logical = bytearray(logical)
    _set_block_device_alignment_offset(logical, lp.SECTOR_SIZE)
    source = _write_sparse(tmp_path, "misaligned.img", logical)
    destination = tmp_path / "misaligned-grown.img"

    with pytest.raises(LpGrowError, match="conflicts with sparse-block alignment"):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert not destination.exists()


def test_backup_slot_corruption_is_refused(tmp_path: Path) -> None:
    """Every primary/backup metadata slot pair is checked before writing."""
    backup_slot_1 = lp.METADATA_START + SLOT_COUNT * METADATA_MAX + METADATA_MAX + 300
    source, _logical = make_super(tmp_path, corrupt=backup_slot_1)
    destination = tmp_path / "corrupt.img"

    with pytest.raises(lp.LpMetadataError):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".corrupt.img.partial"))


def test_raw_super_and_non_growth_requests_are_refused(tmp_path: Path) -> None:
    """The writer only accepts sparse supers and strictly increasing partition sizes."""
    source, logical = make_super(tmp_path)
    raw = tmp_path / "raw.img"
    raw.write_bytes(logical)
    with pytest.raises(LpGrowError, match="sparse super"):
        grow_partition(raw, "system_a", 2 * MIB, tmp_path / "raw-grown.img")

    with pytest.raises(LpGrowError, match="must exceed"):
        grow_partition(source, "system_a", MIB, tmp_path / "same-size.img")
    assert not (tmp_path / "raw-grown.img").exists()
    assert not (tmp_path / "same-size.img").exists()


def test_existing_output_is_never_overwritten(tmp_path: Path) -> None:
    """A pre-existing destination remains byte-identical."""
    source, _logical = make_super(tmp_path)
    destination = tmp_path / "existing.img"
    destination.write_bytes(b"keep")

    with pytest.raises(LpGrowError, match="already exists"):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert destination.read_bytes() == b"keep"


def test_dangling_partial_symlink_and_referent_are_preserved(tmp_path: Path) -> None:
    """Exclusive no-follow creation refuses a dangling partial symlink without cleanup."""
    source, _logical = make_super(tmp_path)
    destination = tmp_path / "symlink-grown.img"
    partial = tmp_path / ".symlink-grown.img.partial"
    referent = tmp_path / "referent.img"
    referent.write_bytes(b"untouched")
    partial.symlink_to(referent)

    with pytest.raises(LpGrowError, match="partial output already exists"):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert partial.is_symlink()
    assert partial.resolve() == referent
    assert referent.read_bytes() == b"untouched"
    assert not destination.exists()


def _build_extended_entry_super(tmp_path: Path) -> tuple[Path, bytes]:
    """Build a sparse super with unknown header, table-entry, and group bytes."""
    logical = bytearray(DEVICE_SIZE)
    geometry = build_geometry()
    logical[lp.GEOMETRY_OFFSET : lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE] = geometry
    logical[lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE : lp.METADATA_START] = geometry

    partition_specs = (
        ("system_ext_a", 1, 0, ((MIB, MIB),)),
        ("other_a", 2, 0, ((3 * MIB, 256 * KIB),)),
    )
    partition_entry_size = 56
    extent_entry_size = 32
    group_entry_size = 52
    device_entry_size = 72
    partition_table = bytearray()
    extent_table = bytearray()
    extent_index = 0
    for name, group, _unused, extents in partition_specs:
        first = extent_index
        for physical_offset, size in extents:
            extent_table.extend(
                struct.pack(
                    "<QIQI",
                    size // lp.SECTOR_SIZE,
                    0,
                    physical_offset // lp.SECTOR_SIZE,
                    0,
                )
            )
            extent_table.extend(f"E{extent_index:03d}".encode())
            extent_table.extend(bytes(4))
            extent_index += 1
        partition_table.extend(
            struct.pack(
                "<36sIIII",
                name.encode(),
                1,
                first,
                len(extents),
                group,
            )
        )
        partition_table.extend(f"P{len(partition_specs):03d}".encode())

    group_table = bytearray()
    for index, name in enumerate(GROUPS):
        group_table.extend(struct.pack("<36sIQ", name.encode(), 0, 0))
        group_table.extend(f"G{index:03d}".encode())
    device_table = bytearray(struct.pack("<QIIQ36sI", 2048, MIB, 0, DEVICE_SIZE, b"super", 0))
    device_table.extend(b"DEVICE!!")

    tables = bytes(partition_table) + bytes(extent_table) + bytes(group_table) + bytes(device_table)
    header = bytearray(256)
    struct.pack_into("<IHHI", header, 0, lp.LP_METADATA_MAGIC, 10, 2, len(header))
    struct.pack_into("<I", header, 44, len(tables))
    header[48:80] = hashlib.sha256(tables).digest()
    descriptors = (
        (0, len(partition_specs), partition_entry_size),
        (len(partition_table), extent_index, extent_entry_size),
        (
            len(partition_table) + len(extent_table),
            len(GROUPS),
            group_entry_size,
        ),
        (
            len(partition_table) + len(extent_table) + len(group_table),
            1,
            device_entry_size,
        ),
    )
    for index, descriptor in enumerate(descriptors):
        struct.pack_into("<III", header, 80 + index * 12, *descriptor)
    struct.pack_into("<I", header, 128, 1)
    header[200:209] = b"KEEP-THIS"
    header[12:44] = hashlib.sha256(header).digest()
    metadata = bytes(header) + tables + bytes(METADATA_MAX - len(header) - len(tables))
    for copy in range(2 * SLOT_COUNT):
        start = lp.METADATA_START + copy * METADATA_MAX
        logical[start : start + METADATA_MAX] = metadata

    logical[MIB : 2 * MIB] = make_content(MIB, 501)
    logical[3 * MIB : 3 * MIB + 256 * KIB] = make_content(256 * KIB, 502)
    return _write_sparse(tmp_path, "extended.img", logical), bytes(logical)


def _metadata_tables(path: Path) -> tuple[bytes, bytes, bytes, bytes, bytes, bytes]:
    with path.open("rb") as stream:
        metadata = sparse.read_range(stream, lp.METADATA_START, METADATA_MAX)
    header_size = struct.unpack_from("<I", metadata, 8)[0]
    tables_size = struct.unpack_from("<I", metadata, 44)[0]
    tables = metadata[header_size : header_size + tables_size]
    descriptors = [struct.unpack_from("<III", metadata, 80 + index * 12) for index in range(4)]
    entries = []
    for offset, count, entry_size in descriptors:
        entries.append(tables[offset : offset + count * entry_size])
    return metadata[:header_size], tables, *entries


def test_unknown_header_and_table_entry_bytes_are_preserved(tmp_path: Path) -> None:
    """Growing relocates tables without discarding opaque header or entry extensions."""
    source, _logical = _build_extended_entry_super(tmp_path)
    destination = tmp_path / "extended-grown.img"
    old_header, _old_tables, old_partitions, old_extents, old_groups, old_devices = (
        _metadata_tables(source)
    )

    grow_partition(source, "system_ext_a", 2 * MIB, destination)

    new_header, _new_tables, new_partitions, new_extents, new_groups, new_devices = (
        _metadata_tables(destination)
    )
    assert new_header[200:209] == old_header[200:209] == b"KEEP-THIS"
    partition_entry_size = 56
    assert new_partitions[:44] == old_partitions[:44]
    assert new_partitions[52:partition_entry_size] == old_partitions[52:partition_entry_size]
    assert struct.unpack_from("<II", new_partitions, 40) == (0, 2)
    assert (
        new_partitions[partition_entry_size : partition_entry_size + 40]
        == old_partitions[partition_entry_size : partition_entry_size + 40]
    )
    assert (
        new_partitions[partition_entry_size + 52 : 2 * partition_entry_size]
        == old_partitions[partition_entry_size + 52 : 2 * partition_entry_size]
    )
    assert struct.unpack_from("<II", new_partitions, partition_entry_size + 40) == (2, 1)
    assert new_extents[:32] == old_extents[:32]
    assert new_extents[56:64] == bytes(8)
    assert new_extents[64:96] == old_extents[32:64]
    assert new_groups == old_groups
    assert new_devices == old_devices


def test_active_slots_with_different_layouts_are_refused(tmp_path: Path) -> None:
    """A divergent metadata slot is not silently overwritten with another slot's layout."""
    _original, logical = make_super(tmp_path)
    logical = bytearray(logical)

    def edit(metadata: bytearray) -> None:
        header_size = struct.unpack_from("<I", metadata, 8)[0]
        tables_size = struct.unpack_from("<I", metadata, 44)[0]
        tables = memoryview(metadata)[header_size : header_size + tables_size]
        offset, _count, _entry_size = struct.unpack_from("<III", metadata, 104)
        struct.pack_into("<I", tables, offset + 36, 1)

    # Only slot 1 receives a different group flags field; both of its copies remain valid.
    metadata_start = lp.METADATA_START + METADATA_MAX
    metadata_end = metadata_start + METADATA_MAX
    metadata = bytearray(logical[metadata_start:metadata_end])
    edit(metadata)
    _refresh_metadata_checksum(metadata)
    logical[metadata_start:metadata_end] = metadata
    backup_start = lp.METADATA_START + SLOT_COUNT * METADATA_MAX + METADATA_MAX
    logical[backup_start : backup_start + METADATA_MAX] = metadata
    source = _write_sparse(tmp_path, "divergent.img", logical)
    destination = tmp_path / "divergent-grown.img"

    with pytest.raises(LpGrowError, match="different partition layouts"):
        grow_partition(source, "system_a", 2 * MIB, destination)

    assert not destination.exists()
