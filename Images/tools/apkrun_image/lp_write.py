"""Replace the data of one linear logical partition in a liblp super image (#099, IR-680).

The writer changes the bytes of one existing linear partition. The geometry, the metadata copies,
and the partition table stay byte-identical, so the metadata does not change and its checksums stay
valid. A new image may be smaller than its partition: the rest of the partition is zero. A larger
image is refused with `PartitionTooLargeError`, because growing a partition changes the metadata,
and this writer does not make that change (IR-682).

The super must be a sparse image, the form that the manifest records. The output is a sparse image
whose chunks outside the partition are the input's chunk records, so the free space between
partitions is copied, not changed. `rewrite_ranges` encodes the new data. Before the output is
published, the writer compares the partition table, the metadata bytes, the checksums of every
metadata copy, the new data, and every other partition with data against the input. The free space
is not compared separately.
"""

from __future__ import annotations

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


class LpWriteError(ValueError):
    """A super image or a replacement that this writer does not handle."""


class PartitionTooLargeError(LpWriteError):
    """The new image is larger than its partition, and growing a partition is not supported."""

    def __init__(self, partition: str, image_size: int, partition_size: int) -> None:
        super().__init__(
            f"{partition}: the image has {image_size} bytes and the partition holds "
            f"{partition_size}; the writer does not grow a partition"
        )
        self.partition = partition
        self.image_size = image_size
        self.partition_size = partition_size


@dataclass(frozen=True)
class ReplaceResult:
    """What the writer replaced, and what it checked in the output."""

    partition: str
    image_size: int
    partition_size: int
    physical_ranges: int
    output_chunks: int
    metadata_copies_checked: int
    partitions_compared: int


def _size_of(stream: BinaryIO) -> int:
    stream.seek(0, 2)
    size = stream.tell()
    stream.seek(0)
    return size


def _read_geometry(stream: BinaryIO, offset: int) -> lp.Geometry:
    return lp.parse_geometry(read_range(stream, offset, lp.GEOMETRY_SIZE))


def _metadata_region_end(geometry: lp.Geometry) -> int:
    """Return the end of the primary and backup metadata slots (IR-681, stock layout)."""
    return lp.METADATA_START + 2 * geometry.metadata_slot_count * geometry.metadata_max_size


def check_copies(stream: BinaryIO) -> int:
    """Check the checksums of both geometry copies and of every metadata copy in use.

    Each primary slot is at `METADATA_START + slot * metadata_max_size`, and each backup slot
    follows the primary slots. A slot that is entirely zero is unused and is skipped. Any other
    slot is parsed, so a damaged magic or a checksum mismatch is refused. Return the number of
    copies that were checked. Raise `LpMetadataError` for a checksum or layout mismatch.
    """
    primary = _read_geometry(stream, lp.GEOMETRY_OFFSET)
    backup = _read_geometry(stream, lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE)
    if backup != primary:
        raise lp.LpMetadataError("the backup liblp geometry differs from the primary geometry")
    copies = 2
    slot_bases = (
        lp.METADATA_START,
        lp.METADATA_START + primary.metadata_slot_count * primary.metadata_max_size,
    )
    for base in slot_bases:
        for slot in range(primary.metadata_slot_count):
            offset = base + slot * primary.metadata_max_size
            blob = read_range(stream, offset, primary.metadata_max_size)
            if blob == bytes(len(blob)):
                continue
            lp.parse_metadata(blob, primary)
            copies += 1
    return copies


def _plan(
    super_stream: BinaryIO, partition: str, image_stream: BinaryIO
) -> tuple[lp.Metadata, lp.LogicalPartition, list[RangeReplacement], int]:
    """Check the inputs and return the partition's replacements in its own order."""
    head = super_stream.read(4)
    super_stream.seek(0)
    if head != struct.pack("<I", SPARSE_MAGIC):
        raise LpWriteError(
            "the super image is not a sparse image; only sparse super images are written"
        )
    metadata = lp.read_dynamic_partitions(super_stream, sparse=True)
    if metadata is None:
        raise LpWriteError("the super image has no liblp metadata")
    target = next((item for item in metadata.logical_partitions if item.name == partition), None)
    if target is None:
        raise LpWriteError(f"{partition}: the super image has no such logical partition")
    image_size = _size_of(image_stream)
    if image_size == 0:
        raise LpWriteError(f"{partition}: the image is empty")
    if image_size > target.size:
        raise PartitionTooLargeError(partition, image_size, target.size)

    geometry = _read_geometry(super_stream, lp.GEOMETRY_OFFSET)
    metadata_end = _metadata_region_end(geometry)
    block_size = read_header(super_stream).block_size
    replacements: list[RangeReplacement] = []
    logical = 0
    for index, extent in enumerate(target.extents):
        if extent.target_type != LINEAR_TARGET or extent.target_source != 0:
            raise LpWriteError(f"{partition}: extent {index} is not linear on the super device")
        physical = extent.target_data * SECTOR_SIZE
        size = extent.size
        if physical < metadata_end:
            raise LpWriteError(f"{partition}: extent {index} overlaps the liblp metadata")
        if physical % block_size or size % block_size:
            raise LpWriteError(
                f"{partition}: extent {index} is not aligned to the {block_size}-byte sparse block"
            )
        source_size = max(0, min(size, image_size - logical))
        replacements.append(
            RangeReplacement(
                offset=physical,
                size=size,
                source=image_stream,
                source_offset=logical,
                source_size=source_size,
            )
        )
        logical += size
    return metadata, target, replacements, image_size


def _compare_partition(
    output: BinaryIO, partition: lp.LogicalPartition, image: BinaryIO, image_size: int
) -> None:
    """Check that the partition in the output holds the image, then zeros."""
    offset = 0
    while offset < partition.size:
        size = min(COMPARE_CHUNK, partition.size - offset)
        present = max(0, min(size, image_size - offset))
        image.seek(offset)
        expected = image.read(present) + bytes(size - present)
        if lp.read_partition_range(output, partition, offset, size, sparse=True) != expected:
            raise LpWriteError(
                f"{partition.name}: the written data differs from the image at offset {offset}"
            )
        offset += size


def _compare_unchanged(source: BinaryIO, output: BinaryIO, partition: lp.LogicalPartition) -> None:
    """Check that a partition's data in the output equals its data in the input."""
    offset = 0
    while offset < partition.size:
        size = min(COMPARE_CHUNK, partition.size - offset)
        before = lp.read_partition_range(source, partition, offset, size, sparse=True)
        after = lp.read_partition_range(output, partition, offset, size, sparse=True)
        if before != after:
            raise LpWriteError(f"{partition.name}: its data changed at offset {offset}")
        offset += size


def _write(
    super_stream: BinaryIO, partition: str, image_stream: BinaryIO, out: BinaryIO
) -> ReplaceResult:
    """Write the replaced super into `out` and check the result against the input."""
    metadata, target, replacements, image_size = _plan(super_stream, partition, image_stream)
    output_chunks = rewrite_ranges(super_stream, out, replacements)
    out.flush()
    os.fsync(out.fileno())

    out.seek(0)
    if lp.read_dynamic_partitions(out, sparse=True) != metadata:
        raise LpWriteError("the written partition table differs from the input")
    region = _metadata_region_end(_read_geometry(super_stream, lp.GEOMETRY_OFFSET))
    if read_range(out, 0, region) != read_range(super_stream, 0, region):
        raise LpWriteError("the written geometry or metadata bytes differ from the input")
    copies = check_copies(out)
    _compare_partition(out, target, image_stream, image_size)

    compared = 0
    for other in metadata.logical_partitions:
        if other.name == partition or other.size == 0:
            continue
        _compare_unchanged(super_stream, out, other)
        compared += 1
    return ReplaceResult(
        partition=partition,
        image_size=image_size,
        partition_size=target.size,
        physical_ranges=len(replacements),
        output_chunks=output_chunks,
        metadata_copies_checked=copies,
        partitions_compared=compared,
    )


def replace_partition(
    source: Path, partition: str, image: Path, destination: Path
) -> ReplaceResult:
    """Write a copy of the sparse super `source` with `partition` holding `image`.

    `destination` must not exist, and it must be in a directory that exists. The copy is written
    beside it as a partial file, checked, and then linked to `destination`. The link fails if the
    destination exists, so no file is overwritten, and a failed write leaves no output.

    Raise `LpWriteError` or `PartitionTooLargeError` for an input or an output that the writer
    refuses. Raise `LpMetadataError` for damaged liblp metadata, and `SparseImageError` for a
    damaged or unsupported sparse container.
    """
    partial = destination.with_name(f".{destination.name}.partial")
    if source.resolve() == destination.resolve():
        raise LpWriteError("the output must not be the super image that it is written from")
    if partial.resolve() in (source.resolve(), image.resolve()):
        raise LpWriteError(f"{partial}: the partial name is an input")
    if destination.exists():
        raise LpWriteError(f"{destination}: the output already exists")
    try:
        with (
            source.open("rb") as super_stream,
            image.open("rb") as image_stream,
            partial.open("w+b") as out,
        ):
            result = _write(super_stream, partition, image_stream, out)
        try:
            os.link(partial, destination)
        except FileExistsError as error:
            raise LpWriteError(f"{destination}: the output already exists") from error
        partial.unlink()
    except BaseException:
        partial.unlink(missing_ok=True)
        raise
    return result
