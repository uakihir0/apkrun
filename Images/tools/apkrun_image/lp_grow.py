"""Grow one logical partition in a sparse liblp super image."""

from __future__ import annotations

import hashlib
import io
import math
import os
import struct
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

from apkrun_image import lp
from apkrun_image.sparse import (
    SPARSE_MAGIC,
    RangeReplacement,
    read_header,
    read_range,
    rewrite_ranges,
)

SECTOR_SIZE = lp.SECTOR_SIZE
COMPARE_CHUNK = 8 * 1024 * 1024
LINEAR_TARGET = 0
ZERO_TARGET = 1


class LpGrowError(ValueError):
    """A sparse super image or requested partition growth is unsupported."""


class GroupSizeExceededError(LpGrowError):
    """Growing a partition would exceed its liblp group maximum size."""


@dataclass(frozen=True)
class GrowResult:
    """The verified result of growing one logical partition."""

    partition: str
    previous_size: int
    partition_size: int
    allocated_extents: tuple[lp.Extent, ...]
    metadata_copies_updated: int
    other_partitions_verified: int
    output_chunks: int


@dataclass(frozen=True)
class _Descriptor:
    offset: int
    count: int
    entry_size: int


@dataclass(frozen=True)
class _Group:
    name: str
    flags: int
    maximum_size: int


@dataclass(frozen=True)
class _BlockDevice:
    first_logical_sector: int
    alignment: int
    alignment_offset: int
    size: int
    name: str
    flags: int


@dataclass(frozen=True)
class _Partition:
    raw_entry: bytes
    name: str
    first_extent: int
    extent_count: int
    group_index: int
    extents: tuple[lp.Extent, ...]

    @property
    def parsed_size(self) -> int:
        """Return the logical size represented by this partition's extents."""
        return sum(extent.size for extent in self.extents)


@dataclass(frozen=True)
class _Slot:
    index: int
    offset: int
    raw: bytes
    parsed: lp.Metadata
    header_size: int
    tables_size: int
    descriptors: tuple[_Descriptor, _Descriptor, _Descriptor, _Descriptor]
    tables: bytes
    partitions: tuple[_Partition, ...]
    groups: tuple[_Group, ...]
    block_devices: tuple[_BlockDevice, ...]


def _decode_name(raw: bytes, context: str) -> str:
    """Decode one fixed-width liblp UTF-8 name."""
    value = raw.split(b"\0", 1)[0]
    if not value:
        raise lp.LpMetadataError(f"{context} has an empty name")
    try:
        name = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise lp.LpMetadataError(f"{context} has a non-UTF-8 name") from error
    if "/" in name or name in {".", ".."}:
        raise lp.LpMetadataError(f"{context} has an invalid name")
    return name


def _read_descriptor(header: bytes, index: int) -> _Descriptor:
    offset, count, entry_size = struct.unpack_from("<III", header, 80 + index * 12)
    return _Descriptor(offset=offset, count=count, entry_size=entry_size)


def _descriptor_bytes(descriptor: _Descriptor, minimum_size: int, tables_size: int) -> int:
    if descriptor.count == 0:
        if descriptor.offset > tables_size:
            raise lp.LpMetadataError("an empty liblp table starts past the table data")
        return 0
    if descriptor.entry_size < minimum_size:
        raise lp.LpMetadataError("a liblp table entry is smaller than its structure")
    byte_count = descriptor.count * descriptor.entry_size
    if descriptor.offset > tables_size or byte_count > tables_size - descriptor.offset:
        raise lp.LpMetadataError("a liblp table extends past the table data")
    return byte_count


def _validate_descriptor_ranges(
    descriptors: tuple[_Descriptor, _Descriptor, _Descriptor, _Descriptor],
    minimum_sizes: tuple[int, int, int, int],
    tables_size: int,
) -> None:
    occupied: list[tuple[int, int]] = []
    for descriptor, minimum_size in zip(descriptors, minimum_sizes, strict=True):
        byte_count = _descriptor_bytes(descriptor, minimum_size, tables_size)
        if byte_count:
            occupied.append((descriptor.offset, descriptor.offset + byte_count))
    occupied.sort()
    for previous, current in zip(occupied, occupied[1:], strict=False):
        if current[0] < previous[1]:
            raise lp.LpMetadataError("liblp metadata tables overlap")


def _parse_slot(raw: bytes, geometry: lp.Geometry, index: int, offset: int) -> _Slot:
    parsed = lp.parse_metadata(raw, geometry)
    _magic, _major, _minor, header_size = struct.unpack_from("<IHHI", raw)
    tables_size = struct.unpack_from("<I", raw, 44)[0]
    header = raw[:header_size]
    tables = raw[header_size : header_size + tables_size]
    descriptors = tuple(_read_descriptor(header, table) for table in range(4))
    minimum_sizes = (
        lp.PARTITION_ENTRY_SIZE,
        lp.EXTENT_ENTRY_SIZE,
        lp.GROUP_ENTRY_SIZE,
        lp.BLOCK_DEVICE_ENTRY_SIZE,
    )
    _validate_descriptor_ranges(descriptors, minimum_sizes, tables_size)  # type: ignore[arg-type]

    partition_table, extent_table, group_table, device_table = descriptors
    raw_extents = tuple(
        tables[
            extent_table.offset + item * extent_table.entry_size : extent_table.offset
            + (item + 1) * extent_table.entry_size
        ]
        for item in range(extent_table.count)
    )

    groups: list[_Group] = []
    for item in range(group_table.count):
        start = group_table.offset + item * group_table.entry_size
        entry = tables[start : start + group_table.entry_size]
        groups.append(
            _Group(
                name=_decode_name(entry[:36], f"liblp group {item}"),
                flags=struct.unpack_from("<I", entry, 36)[0],
                maximum_size=struct.unpack_from("<Q", entry, 40)[0],
            )
        )
    if len({group.name for group in groups}) != len(groups):
        raise lp.LpMetadataError("duplicate liblp group name")

    block_devices: list[_BlockDevice] = []
    for item in range(device_table.count):
        start = device_table.offset + item * device_table.entry_size
        entry = tables[start : start + device_table.entry_size]
        block_devices.append(
            _BlockDevice(
                first_logical_sector=struct.unpack_from("<Q", entry, 0)[0],
                alignment=struct.unpack_from("<I", entry, 8)[0],
                alignment_offset=struct.unpack_from("<I", entry, 12)[0],
                size=struct.unpack_from("<Q", entry, 16)[0],
                name=_decode_name(entry[24:60], f"liblp block device {item}"),
                flags=struct.unpack_from("<I", entry, 60)[0],
            )
        )

    partitions: list[_Partition] = []
    referenced_extents: set[int] = set()
    for item in range(partition_table.count):
        start = partition_table.offset + item * partition_table.entry_size
        entry = tables[start : start + partition_table.entry_size]
        name = _decode_name(entry[:36], f"liblp partition {item}")
        first_extent, extent_count, group_index = struct.unpack_from("<III", entry, 40)
        if first_extent > len(raw_extents) or extent_count > len(raw_extents) - first_extent:
            raise lp.LpMetadataError(f"liblp partition {name!r} references missing extents")
        indexes = set(range(first_extent, first_extent + extent_count))
        if referenced_extents.intersection(indexes):
            raise lp.LpMetadataError("liblp partitions share extent-table entries")
        referenced_extents.update(indexes)
        partitions.append(
            _Partition(
                raw_entry=entry,
                name=name,
                first_extent=first_extent,
                extent_count=extent_count,
                group_index=group_index,
                extents=(),
            )
        )

    # The public parser sorts partitions by name. Preserve table order and attach the matching
    # parsed extents without relying on the order of its result.
    parsed_by_name = {item.name: item for item in parsed.logical_partitions}
    partitions = [
        _Partition(
            raw_entry=part.raw_entry,
            name=part.name,
            first_extent=part.first_extent,
            extent_count=part.extent_count,
            group_index=part.group_index,
            extents=parsed_by_name[part.name].extents,
        )
        for part in partitions
    ]

    return _Slot(
        index=index,
        offset=offset,
        raw=raw,
        parsed=parsed,
        header_size=header_size,
        tables_size=tables_size,
        descriptors=descriptors,  # type: ignore[arg-type]
        tables=tables,
        partitions=tuple(partitions),
        groups=tuple(groups),
        block_devices=tuple(block_devices),
    )


def _signature(slot: _Slot) -> tuple[object, ...]:
    partitions = tuple(
        sorted(
            (
                part.name,
                part.group_index,
                tuple(part.extents),
            )
            for part in slot.partitions
        )
    )
    groups = tuple((group.name, group.flags, group.maximum_size) for group in slot.groups)
    devices = tuple(
        (
            device.first_logical_sector,
            device.alignment,
            device.alignment_offset,
            device.size,
            device.name,
            device.flags,
        )
        for device in slot.block_devices
    )
    return partitions, groups, devices


def _alignment(value: int, modulus: int, residue: int = 0) -> int:
    """Return the smallest value at least `value` in one alignment congruence class."""
    return value + ((residue - value) % modulus)


def _combined_alignment(alignment: int, offset: int, sparse_block_size: int) -> tuple[int, int]:
    """Combine liblp device and sparse-block alignment constraints with CRT."""
    if alignment == 0:
        if offset:
            raise lp.LpMetadataError("a block-device alignment offset requires an alignment")
        return sparse_block_size, 0
    if offset >= alignment:
        raise lp.LpMetadataError("the block-device alignment offset is out of range")
    common = math.gcd(alignment, sparse_block_size)
    if offset % common:
        raise LpGrowError("the block-device alignment offset conflicts with sparse-block alignment")
    device_modulus = alignment // common
    sparse_factor = sparse_block_size // common
    if device_modulus == 1:
        multiplier = 0
    else:
        multiplier = ((offset // common) * pow(sparse_factor, -1, device_modulus)) % device_modulus
    modulus = math.lcm(alignment, sparse_block_size)
    return modulus, (sparse_block_size * multiplier) % modulus


def _ceil_multiple(value: int, quantum: int) -> int:
    return ((value + quantum - 1) // quantum) * quantum


def _read_slots(stream: BinaryIO, logical_size: int) -> tuple[lp.Geometry, list[_Slot]]:
    geometry_a = read_range(stream, lp.GEOMETRY_OFFSET, lp.GEOMETRY_SIZE)
    geometry_b = read_range(stream, lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE, lp.GEOMETRY_SIZE)
    parsed_a = lp.parse_geometry(geometry_a)
    parsed_b = lp.parse_geometry(geometry_b)
    if parsed_a != parsed_b:
        raise lp.LpMetadataError("the primary and backup liblp geometry differ")

    metadata_end = lp.METADATA_START + 2 * parsed_a.metadata_slot_count * parsed_a.metadata_max_size
    if metadata_end > logical_size:
        raise lp.LpMetadataError("the liblp metadata region extends past the sparse image")

    slots: list[_Slot] = []
    backup_start = lp.METADATA_START + parsed_a.metadata_slot_count * parsed_a.metadata_max_size
    for index in range(parsed_a.metadata_slot_count):
        primary_offset = lp.METADATA_START + index * parsed_a.metadata_max_size
        backup_offset = backup_start + index * parsed_a.metadata_max_size
        primary = read_range(stream, primary_offset, parsed_a.metadata_max_size)
        backup = read_range(stream, backup_offset, parsed_a.metadata_max_size)
        if not any(primary) and not any(backup):
            continue
        if not any(primary) or not any(backup):
            raise lp.LpMetadataError(
                f"liblp metadata slot {index} has only one primary/backup copy"
            )
        if primary != backup:
            raise lp.LpMetadataError(f"primary and backup liblp metadata slot {index} differ")
        slots.append(_parse_slot(primary, parsed_a, index, primary_offset))
    if not slots:
        raise lp.LpMetadataError("liblp has no active metadata slots")
    if slots[0].index != 0:
        raise LpGrowError("the first liblp metadata slot is inactive")
    if any(_signature(slot) != _signature(slots[0]) for slot in slots[1:]):
        raise LpGrowError("active liblp metadata slots have different partition layouts")
    return parsed_a, slots


def partition_growth_limit(source: Path, partition_name: str) -> int:
    """Return an upper bound for a logical partition's aligned size after safe growth.

    The bound accounts for its group maximum and the total free, aligned ranges on the backing
    device. `grow_partition` still performs the authoritative allocation and verifies every
    metadata copy before publishing output.
    """
    try:
        with source.open("rb") as stream:
            stream.seek(0)
            if stream.read(4) != struct.pack("<I", SPARSE_MAGIC):
                raise LpGrowError("only Android sparse super images can be inspected for growth")
            header = read_header(stream)
            geometry, slots = _read_slots(stream, header.logical_size)
    except OSError as error:
        raise LpGrowError(f"{source}: could not inspect the sparse super: {error}") from None

    base = slots[0]
    partition = next((item for item in base.partitions if item.name == partition_name), None)
    if partition is None:
        raise LpGrowError(f"{partition_name}: the super image has no such logical partition")
    if partition.group_index >= len(base.groups):
        raise lp.LpMetadataError(f"{partition_name}: its liblp group index is invalid")
    if not partition.extents or any(
        extent.target_type != LINEAR_TARGET or extent.target_source != 0
        for extent in partition.extents
    ):
        raise LpGrowError(f"{partition_name}: existing extents cannot be safely grown")

    group = base.groups[partition.group_index]
    group_usage = sum(
        item.parsed_size
        for item in base.partitions
        if base.groups[item.group_index].name == group.name
    )
    if group.maximum_size and group_usage > group.maximum_size:
        raise lp.LpMetadataError(f"liblp group {group.name!r} exceeds its maximum size")
    group_limit = (
        partition.parsed_size + group.maximum_size - group_usage
        if group.maximum_size
        else base.block_devices[0].size
    )

    device = base.block_devices[0]
    metadata_end = lp.METADATA_START + 2 * geometry.metadata_slot_count * geometry.metadata_max_size
    lower_bound = max(metadata_end, device.first_logical_sector * SECTOR_SIZE)
    occupied = _physical_intervals(slots, device.size, metadata_end)
    alignment, residue = _combined_alignment(
        device.alignment,
        device.alignment_offset,
        header.block_size,
    )
    quantum = math.lcm(header.block_size, geometry.logical_block_size)
    free_capacity = 0
    cursor = lower_bound
    for start, end in occupied:
        if end <= lower_bound:
            continue
        if start > cursor:
            aligned = _alignment(cursor, alignment, residue)
            if aligned < start:
                free_capacity += ((start - aligned) // quantum) * quantum
        cursor = max(cursor, end)
        if cursor >= device.size:
            break
    if cursor < device.size:
        aligned = _alignment(cursor, alignment, residue)
        if aligned < device.size:
            free_capacity += ((device.size - aligned) // quantum) * quantum

    device_limit = partition.parsed_size + free_capacity
    return min(group_limit, device_limit) // quantum * quantum


def _physical_intervals(
    slots: list[_Slot], block_device_size: int, metadata_end: int
) -> list[tuple[int, int]]:
    intervals: list[tuple[int, int]] = [(0, metadata_end)]
    for slot in slots:
        slot_intervals: list[tuple[int, int]] = []
        for partition in slot.partitions:
            for extent in partition.extents:
                if extent.target_type == ZERO_TARGET:
                    continue
                if extent.target_type != LINEAR_TARGET or extent.target_source != 0:
                    raise LpGrowError("only linear extents on the first block device can be grown")
                start = extent.target_data * SECTOR_SIZE
                end = start + extent.size
                if start < metadata_end:
                    raise lp.LpMetadataError("a linear extent overlaps the liblp metadata region")
                if end > block_device_size:
                    raise lp.LpMetadataError("a linear extent extends past its block device")
                slot_intervals.append((start, end))
        slot_intervals.sort()
        for previous, current in zip(slot_intervals, slot_intervals[1:], strict=False):
            if current[0] < previous[1]:
                raise lp.LpMetadataError("liblp linear extents overlap")
        intervals.extend(slot_intervals)
    intervals.sort()
    merged: list[tuple[int, int]] = []
    for start, end in intervals:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def _allocate_extents(
    slots: list[_Slot],
    *,
    partition_name: str,
    new_size: int,
    sparse_block_size: int,
    logical_block_size: int,
    metadata_end: int,
    block_device: _BlockDevice,
) -> tuple[int, tuple[lp.Extent, ...]]:
    base = slots[0]
    by_name = {part.name: part for part in base.partitions}
    target = by_name.get(partition_name)
    if target is None:
        raise LpGrowError(f"{partition_name}: the super image has no such logical partition")
    if not target.extents:
        raise LpGrowError(f"{partition_name}: an empty logical partition cannot be grown")
    if any(
        extent.target_type != LINEAR_TARGET or extent.target_source != 0
        for extent in target.extents
    ):
        raise LpGrowError(f"{partition_name}: existing extents are not linear on the super device")
    if new_size <= target.parsed_size:
        raise LpGrowError(
            f"{partition_name}: requested size {new_size} must exceed its current size "
            f"{target.parsed_size}"
        )

    if block_device.alignment and block_device.alignment % SECTOR_SIZE:
        raise lp.LpMetadataError("the block-device alignment is not sector aligned")
    if block_device.alignment_offset % SECTOR_SIZE:
        raise lp.LpMetadataError("the block-device alignment offset is not sector aligned")
    start_alignment, alignment_residue = _combined_alignment(
        block_device.alignment,
        block_device.alignment_offset,
        sparse_block_size,
    )
    size_quantum = math.lcm(sparse_block_size, logical_block_size)
    allocated_size = _ceil_multiple(new_size - target.parsed_size, size_quantum)
    result_size = target.parsed_size + allocated_size

    group_name = base.groups[target.group_index].name
    group = next(group for group in base.groups if group.name == group_name)
    group_usage = sum(
        part.parsed_size
        for part in base.partitions
        if base.groups[part.group_index].name == group_name
    )
    if group.maximum_size and group_usage - target.parsed_size + result_size > group.maximum_size:
        raise GroupSizeExceededError(
            f"{partition_name}: growing to {result_size} bytes would exceed group "
            f"{group_name!r} maximum size {group.maximum_size}"
        )

    lower_bound = max(
        metadata_end,
        block_device.first_logical_sector * SECTOR_SIZE,
    )
    if lower_bound >= block_device.size:
        raise LpGrowError("the block device has no allocatable space after metadata")
    occupied = _physical_intervals(slots, block_device.size, metadata_end)
    free_ranges: list[tuple[int, int]] = []
    cursor = lower_bound
    for start, end in occupied:
        if end <= lower_bound:
            continue
        if start > cursor:
            free_ranges.append((cursor, min(start, block_device.size)))
        cursor = max(cursor, end)
        if cursor >= block_device.size:
            break
    if cursor < block_device.size:
        free_ranges.append((cursor, block_device.size))

    remaining = allocated_size
    allocated: list[lp.Extent] = []
    for start, end in free_ranges:
        aligned_start = _alignment(start, start_alignment, alignment_residue)
        if aligned_start >= end:
            continue
        available = ((end - aligned_start) // size_quantum) * size_quantum
        amount = min(remaining, available)
        amount -= amount % size_quantum
        if amount <= 0:
            continue
        allocated.append(
            lp.Extent(
                sector_count=amount // SECTOR_SIZE,
                target_type=LINEAR_TARGET,
                target_data=aligned_start // SECTOR_SIZE,
                target_source=0,
            )
        )
        remaining -= amount
        if remaining == 0:
            break
    if remaining:
        raise LpGrowError(
            f"{partition_name}: could not allocate {allocated_size} bytes of unclaimed "
            f"space within the {block_device.size}-byte block device"
        )
    return result_size, tuple(allocated)


def _rewrite_slot(slot: _Slot, partition_name: str, additions: tuple[lp.Extent, ...]) -> bytes:
    partition_table, extent_table, group_table, device_table = slot.descriptors
    raw_extent_entries = [
        slot.tables[
            extent_table.offset + item * extent_table.entry_size : extent_table.offset
            + (item + 1) * extent_table.entry_size
        ]
        for item in range(extent_table.count)
    ]
    target_index = next(
        (index for index, part in enumerate(slot.partitions) if part.name == partition_name),
        None,
    )
    if target_index is None:
        raise LpGrowError(f"{partition_name}: not present in active metadata slot {slot.index}")

    partition_records: list[bytes] = []
    extent_records: list[bytes] = []
    referenced: set[int] = set()
    for index, partition in enumerate(slot.partitions):
        first = len(extent_records)
        for extent_index in range(
            partition.first_extent, partition.first_extent + partition.extent_count
        ):
            if extent_index in referenced:
                raise lp.LpMetadataError("liblp partitions share extent-table entries")
            referenced.add(extent_index)
            extent_records.append(raw_extent_entries[extent_index])
        count = partition.extent_count
        if index == target_index:
            for extent in additions:
                # Existing extension bytes are retained verbatim above. A new entry has no
                # known extension values, so leave them zero rather than copying opaque data.
                entry = bytearray(extent_table.entry_size)
                struct.pack_into(
                    "<QIQI",
                    entry,
                    0,
                    extent.sector_count,
                    extent.target_type,
                    extent.target_data,
                    extent.target_source,
                )
                extent_records.append(bytes(entry))
                count += 1
        entry = bytearray(partition.raw_entry)
        struct.pack_into("<III", entry, 40, first, count, partition.group_index)
        partition_records.append(bytes(entry))

    # Unreferenced extent entries are valid but unused metadata; retain their bytes at the end.
    extent_records.extend(
        entry for index, entry in enumerate(raw_extent_entries) if index not in referenced
    )
    new_partition_table = b"".join(partition_records)
    new_extent_table = b"".join(extent_records)
    tables = bytearray(slot.tables)
    new_partition_offset = _ceil_multiple(len(tables), 8)
    tables.extend(bytes(new_partition_offset - len(tables)))
    tables.extend(new_partition_table)
    new_extent_offset = _ceil_multiple(len(tables), 8)
    tables.extend(bytes(new_extent_offset - len(tables)))
    tables.extend(new_extent_table)
    if len(tables) > 0xFFFFFFFF:
        raise LpGrowError("updated liblp table data exceeds the format's 32-bit size")

    header = bytearray(slot.raw[: slot.header_size])
    struct.pack_into("<I", header, 44, len(tables))
    struct.pack_into(
        "<III",
        header,
        80,
        new_partition_offset,
        partition_table.count,
        partition_table.entry_size,
    )
    struct.pack_into(
        "<III",
        header,
        92,
        new_extent_offset,
        len(extent_records),
        extent_table.entry_size,
    )
    header[48:80] = hashlib.sha256(tables).digest()
    header[12:44] = bytes(32)
    header[12:44] = hashlib.sha256(header).digest()

    prefix = bytes(header) + bytes(tables)
    if len(prefix) > len(slot.raw):
        raise LpGrowError(
            f"liblp slot {slot.index} needs {len(prefix)} bytes but its maximum is {len(slot.raw)}"
        )
    output = bytearray(slot.raw)
    output[: len(prefix)] = prefix
    return bytes(output)


def _read_sparse_plan(
    source: BinaryIO, partition_name: str, minimum_size: int
) -> tuple[
    lp.Geometry,
    list[_Slot],
    tuple[RangeReplacement, ...],
    tuple[lp.Extent, ...],
    int,
    int,
]:
    """Validate a sparse super and plan metadata and allocation writes."""
    source.seek(0)
    if source.read(4) != struct.pack("<I", SPARSE_MAGIC):
        raise LpGrowError("only Android sparse super images can be grown")
    header = read_header(source)
    if header.file_header_size != 28 or header.chunk_header_size != 12:
        raise LpGrowError("only the standard Android sparse header can be rewritten")
    if header.image_checksum:
        raise LpGrowError("a sparse super with a whole-image checksum cannot be rewritten")

    geometry, slots = _read_slots(source, header.logical_size)
    if lp.METADATA_START % header.block_size or geometry.metadata_max_size % header.block_size:
        raise LpGrowError("the liblp metadata slots are incompatible with sparse-block alignment")
    metadata_end = lp.METADATA_START + 2 * geometry.metadata_slot_count * geometry.metadata_max_size
    first = slots[0]
    if len(first.block_devices) != 1:
        raise LpGrowError("only supers with one backing block device can be grown")
    block_device = first.block_devices[0]
    if block_device.size > header.logical_size:
        raise lp.LpMetadataError("the liblp block device exceeds the sparse image size")
    if metadata_end > block_device.size:
        raise lp.LpMetadataError("the liblp metadata region extends past the block device")
    result_size, additions = _allocate_extents(
        slots,
        partition_name=partition_name,
        new_size=minimum_size,
        sparse_block_size=header.block_size,
        logical_block_size=geometry.logical_block_size,
        metadata_end=metadata_end,
        block_device=block_device,
    )

    replacement_ranges: list[RangeReplacement] = []
    for slot in slots:
        new_slot = _rewrite_slot(slot, partition_name, additions)
        copy_offsets = (
            slot.offset,
            lp.METADATA_START
            + geometry.metadata_slot_count * geometry.metadata_max_size
            + slot.index * geometry.metadata_max_size,
        )
        for offset in copy_offsets:
            replacement_ranges.append(
                RangeReplacement(
                    offset=offset,
                    size=geometry.metadata_max_size,
                    source=io.BytesIO(new_slot),
                    source_offset=0,
                    source_size=geometry.metadata_max_size,
                )
            )
    for extent in additions:
        replacement_ranges.append(
            RangeReplacement(
                offset=extent.target_data * SECTOR_SIZE,
                size=extent.size,
            )
        )
    return (
        geometry,
        slots,
        tuple(replacement_ranges),
        additions,
        result_size,
        len(slots) * 2,
    )


def _read_slot_copies(stream: BinaryIO, geometry: lp.Geometry, slots: list[_Slot]) -> list[_Slot]:
    backup_start = lp.METADATA_START + geometry.metadata_slot_count * geometry.metadata_max_size
    output: list[_Slot] = []
    for slot in slots:
        primary = read_range(
            stream,
            lp.METADATA_START + slot.index * geometry.metadata_max_size,
            geometry.metadata_max_size,
        )
        backup = read_range(
            stream,
            backup_start + slot.index * geometry.metadata_max_size,
            geometry.metadata_max_size,
        )
        if primary != backup:
            raise LpGrowError(f"output metadata copies for slot {slot.index} differ")
        output.append(_parse_slot(primary, geometry, slot.index, slot.offset))
    return output


def _compare_partition_data(
    source: BinaryIO,
    output: BinaryIO,
    before: lp.LogicalPartition,
    after: lp.LogicalPartition,
) -> None:
    if before.size > after.size:
        raise LpGrowError(f"{before.name}: output partition unexpectedly shrank")
    offset = 0
    while offset < before.size:
        size = min(COMPARE_CHUNK, before.size - offset)
        old_bytes = lp.read_partition_range(source, before, offset, size, sparse=True)
        new_bytes = lp.read_partition_range(output, after, offset, size, sparse=True)
        if old_bytes != new_bytes:
            raise LpGrowError(f"{before.name}: existing partition data changed at {offset}")
        offset += size
    offset = before.size
    while offset < after.size:
        size = min(COMPARE_CHUNK, after.size - offset)
        if lp.read_partition_range(output, after, offset, size, sparse=True) != bytes(size):
            raise LpGrowError(f"{before.name}: newly allocated partition data is not zero")
        offset += size


def _verify_output(
    source: BinaryIO,
    output: BinaryIO,
    geometry: lp.Geometry,
    old_slots: list[_Slot],
    partition_name: str,
    expected_size: int,
    allocated_extents: tuple[lp.Extent, ...],
) -> int:
    new_slots = _read_slot_copies(output, geometry, old_slots)
    if any(_signature(slot) != _signature(new_slots[0]) for slot in new_slots[1:]):
        raise LpGrowError("updated active liblp metadata slots have different layouts")
    new_by_name = {part.name: part for part in new_slots[0].parsed.logical_partitions}
    old_by_name = {part.name: part for part in old_slots[0].parsed.logical_partitions}
    target = new_by_name.get(partition_name)
    if target is None or target.size != expected_size:
        raise LpGrowError("updated partition size does not match the allocation plan")
    for extent in allocated_extents:
        if extent not in target.extents:
            raise LpGrowError("updated partition metadata lost an allocated extent")

    compared = 0
    for name, before in old_by_name.items():
        after = new_by_name.get(name)
        if after is None:
            raise LpGrowError(f"{name}: a logical partition disappeared")
        if name == partition_name:
            _compare_partition_data(source, output, before, after)
        else:
            if before != after:
                raise LpGrowError(f"{name}: logical partition metadata changed")
            _compare_partition_data(source, output, before, after)
            compared += 1
    return compared


def _write(source: BinaryIO, partition: str, minimum_size: int, output: BinaryIO) -> GrowResult:
    (
        geometry,
        old_slots,
        replacements,
        additions,
        result_size,
        metadata_copies,
    ) = _read_sparse_plan(source, partition, minimum_size)
    source.seek(0)
    chunks = rewrite_ranges(source, output, replacements)
    output.flush()
    os.fsync(output.fileno())

    source.seek(0)
    output.seek(0)
    compared = _verify_output(
        source,
        output,
        geometry,
        old_slots,
        partition,
        result_size,
        additions,
    )
    updated = lp.read_dynamic_partitions(output, sparse=True)
    if updated is None:
        raise LpGrowError("the output super has no liblp metadata")
    before = next(item for item in old_slots[0].parsed.logical_partitions if item.name == partition)
    return GrowResult(
        partition=partition,
        previous_size=before.size,
        partition_size=result_size,
        allocated_extents=additions,
        metadata_copies_updated=metadata_copies,
        other_partitions_verified=compared,
        output_chunks=chunks,
    )


def grow_partition(
    source: Path,
    partition: str,
    minimum_size: int,
    destination: Path,
) -> GrowResult:
    """Grow `partition` to at least `minimum_size` bytes in a sparse super image.

    Growth is rounded up to a complete sparse/logical block. The writer only allocates unclaimed
    aligned linear extents after the liblp metadata and inside the target partition's backing
    device. It updates every active metadata slot and its backup, while preserving unrelated
    header, table-entry, and partition bytes. New extents are zeroed to avoid exposing stale free
    space. The output is written beside `destination`, verified, then linked atomically.

    Raw super images, divergent active slot layouts, multiple backing devices, unsupported sparse
    encodings, and layouts whose free space cannot be proven safe are refused.
    """
    if minimum_size <= 0:
        raise LpGrowError("the requested partition size must be positive")
    if source.resolve() == destination.resolve():
        raise LpGrowError("the output must not be the super image that it is written from")
    partial = destination.with_name(f".{destination.name}.partial")
    if partial.resolve() == source.resolve() or destination.resolve() == partial.resolve():
        raise LpGrowError("the partial output path conflicts with an input or destination")
    if os.path.lexists(destination):
        raise LpGrowError(f"{destination}: the output already exists")
    partial_identity: tuple[int, int] | None = None
    try:
        with source.open("rb") as source_stream:
            flags = os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW
            try:
                output_fd = os.open(partial, flags, 0o600)
            except FileExistsError as error:
                raise LpGrowError(f"{partial}: the partial output already exists") from error
            try:
                created = os.fstat(output_fd)
                partial_identity = (created.st_dev, created.st_ino)
                with os.fdopen(output_fd, "w+b") as output_stream:
                    result = _write(source_stream, partition, minimum_size, output_stream)
            except BaseException:
                try:
                    os.close(output_fd)
                except OSError:
                    pass
                raise
        if not _path_has_identity(partial, partial_identity):
            raise LpGrowError(f"{partial}: the partial output was replaced while writing")
        try:
            os.link(partial, destination, follow_symlinks=False)
        except FileExistsError as error:
            raise LpGrowError(f"{destination}: the output already exists") from error
        linked = destination.lstat()
        if (linked.st_dev, linked.st_ino) != partial_identity:
            raise LpGrowError(f"{destination}: the published output is not the verified image")
        _unlink_if_identity(partial, partial_identity)
        return result
    except BaseException:
        if partial_identity is not None:
            _unlink_if_identity(partial, partial_identity)
        raise


def _path_has_identity(path: Path, identity: tuple[int, int] | None) -> bool:
    """Check a path without following symlinks against a recorded file identity."""
    if identity is None:
        return False
    try:
        current = path.lstat()
    except FileNotFoundError:
        return False
    return (current.st_dev, current.st_ino) == identity


def _unlink_if_identity(path: Path, identity: tuple[int, int]) -> None:
    """Remove a path only while it still names the inode created or linked by this call."""
    if _path_has_identity(path, identity):
        path.unlink()
