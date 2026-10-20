"""Tests for replacing one linear logical partition of a liblp super image (#99, IR-680).

The synthetic super follows the stock layout (IR-681): a primary and a backup geometry block, three
metadata slots with a backup copy of each, a 256-byte header of version 10.2, and empty A/B-style
partitions. Its sparse container mixes RAW, FILL, and DONT_CARE chunks, cut where the partition
extents do not begin or end, so the replacement has to split chunks.
"""

from __future__ import annotations

import dataclasses
import hashlib
import io
import os
import random
import struct
from pathlib import Path

import pytest

from apkrun_image import lp, lp_write, sparse
from apkrun_image.lp import LpMetadataError
from apkrun_image.lp_write import (
    LpWriteError,
    PartitionTooLargeError,
    check_copies,
    replace_partition,
)
from apkrun_image.sparse import (
    CHUNK_DONT_CARE,
    CHUNK_FILL,
    CHUNK_RAW,
    SPARSE_MAGIC,
    RangeReplacement,
    rewrite_ranges,
)

BLOCK = 4096
MIB = 1024 * 1024
KIB = 1024
DEVICE_SIZE = 8 * MIB
METADATA_MAX = 65536
SLOT_COUNT = 3
REGION_END = lp.METADATA_START + 2 * SLOT_COUNT * METADATA_MAX
GROUPS = (
    "default",
    "google_system_dynamic_partitions_a",
    "google_system_dynamic_partitions_b",
    "google_vendor_dynamic_partitions_a",
    "google_vendor_dynamic_partitions_b",
)
# (name, group index, ((byte offset, byte size, target type), ...)), in table order.
STOCK_LIKE = (
    ("product_a", 1, ((2 * MIB, 256 * KIB, 0),)),
    ("product_b", 2, ()),
    ("system_a", 1, ((1 * MIB, 1 * MIB, 0),)),
    ("system_b", 2, ()),
    ("vendor_a", 3, ((3 * MIB, 512 * KIB, 0), (4 * MIB + 512 * KIB, 256 * KIB, 0))),
    ("vendor_b", 4, ()),
)
VENDOR_SIZE = 768 * KIB


def make_content(size: int, seed: int) -> bytes:
    """Return block-aligned data with RAW, FILL, and zero blocks."""
    rng = random.Random(seed)
    blocks = []
    for _ in range(size // BLOCK):
        choice = rng.choice(("raw", "zero", "fill"))
        if choice == "raw":
            blocks.append(rng.randbytes(BLOCK))
        elif choice == "zero":
            blocks.append(bytes(BLOCK))
        else:
            blocks.append(bytes([rng.randrange(1, 256)]) * BLOCK)
    return b"".join(blocks)


def build_metadata(partitions: tuple, device_size: int) -> bytes:
    """Return one checksummed metadata copy in the stock layout (version 10.2, 256-byte header)."""
    partition_table = b""
    extent_table = b""
    extent_count = 0
    for name, group, extents in partitions:
        first = extent_count
        for offset, size, target_type in extents:
            extent_table += struct.pack(
                "<QIQI", size // lp.SECTOR_SIZE, target_type, offset // lp.SECTOR_SIZE, 0
            )
            extent_count += 1
        partition_table += struct.pack("<36sIIII", name.encode(), 1, first, len(extents), group)
    group_table = b"".join(struct.pack("<36sIQ", name.encode(), 0, 0) for name in GROUPS)
    device_table = struct.pack("<QIIQ36sI", 2048, 1024 * 1024, 0, device_size, b"super", 0)
    tables = partition_table + extent_table + group_table + device_table

    header = bytearray(256)
    struct.pack_into("<IHHI", header, 0, lp.LP_METADATA_MAGIC, 10, 2, 256)
    struct.pack_into("<I", header, 44, len(tables))
    header[48:80] = hashlib.sha256(tables).digest()
    descriptors = (
        (0, len(partitions), 52),
        (len(partition_table), extent_count, 24),
        (len(partition_table) + len(extent_table), len(GROUPS), 48),
        (len(partition_table) + len(extent_table) + len(group_table), 1, 64),
    )
    for index, descriptor in enumerate(descriptors):
        struct.pack_into("<III", header, 80 + index * 12, *descriptor)
    struct.pack_into("<I", header, 128, 1)
    header[12:44] = hashlib.sha256(bytes(header)).digest()
    return bytes(header) + tables + bytes(METADATA_MAX - 256 - len(tables))


def build_geometry() -> bytes:
    """Return one checksummed 4096-byte geometry block."""
    geometry = bytearray(lp.GEOMETRY_SIZE)
    struct.pack_into("<II", geometry, 0, lp.LP_GEOMETRY_MAGIC, 52)
    struct.pack_into("<III", geometry, 40, METADATA_MAX, SLOT_COUNT, BLOCK)
    geometry[8:40] = hashlib.sha256(bytes(geometry[:52])).digest()
    return bytes(geometry)


def build_logical(
    partitions: tuple, contents: dict[str, bytes], device_size: int = DEVICE_SIZE
) -> bytearray:
    """Return the expanded super: geometry, metadata copies, and the partition data."""
    image = bytearray(device_size)
    geometry = build_geometry()
    image[lp.GEOMETRY_OFFSET : lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE] = geometry
    image[lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE : lp.METADATA_START] = geometry
    metadata = build_metadata(partitions, device_size)
    for copy in range(2 * SLOT_COUNT):
        start = lp.METADATA_START + copy * METADATA_MAX
        image[start : start + METADATA_MAX] = metadata
    for name, _group, extents in partitions:
        data = contents.get(name, b"")
        consumed = 0
        for offset, size, target_type in extents:
            if target_type == 0:
                piece = data[consumed : consumed + size]
                image[offset : offset + size] = piece + bytes(size - len(piece))
            consumed += size
    return image


def encode_sparse(logical: bytes, *, max_run: int) -> bytes:
    """Encode an expanded image as Android sparse chunks, cutting runs every `max_run` blocks."""

    def classify(block: bytes) -> tuple[int, bytes]:
        if block == bytes(BLOCK):
            return CHUNK_DONT_CARE, b""
        pattern = block[:4]
        if block == pattern * (BLOCK // 4):
            return CHUNK_FILL, pattern
        return CHUNK_RAW, b""

    blocks = len(logical) // BLOCK
    chunks: list[bytes] = []
    index = 0
    while index < blocks:
        kind = classify(logical[index * BLOCK : (index + 1) * BLOCK])
        run = 1
        while (
            index + run < blocks
            and run < max_run
            and classify(logical[(index + run) * BLOCK : (index + run + 1) * BLOCK]) == kind
        ):
            run += 1
        payload = logical[index * BLOCK : (index + run) * BLOCK]
        if kind[0] == CHUNK_RAW:
            chunks.append(struct.pack("<HHII", CHUNK_RAW, 0, run, 12 + len(payload)) + payload)
        elif kind[0] == CHUNK_FILL:
            chunks.append(struct.pack("<HHII", CHUNK_FILL, 0, run, 16) + kind[1])
        else:
            chunks.append(struct.pack("<HHII", CHUNK_DONT_CARE, 0, run, 12))
        index += run
    header = struct.pack("<I4H4I", SPARSE_MAGIC, 1, 0, 28, 12, BLOCK, blocks, len(chunks), 0)
    return header + b"".join(chunks)


def make_super(
    tmp_path: Path,
    partitions: tuple = STOCK_LIKE,
    *,
    seed: int = 1,
    name: str = "super.img",
    corrupt: int | None = None,
) -> tuple[Path, bytes]:
    """Write a synthetic sparse super and return its path and expanded image."""
    contents = {
        item[0]: make_content(sum(extent[1] for extent in item[2]), seed + index)
        for index, item in enumerate(partitions)
        if item[2]
    }
    logical = build_logical(partitions, contents)
    if corrupt is not None:
        logical[corrupt] ^= 0xFF
    path = tmp_path / name
    path.write_bytes(encode_sparse(bytes(logical), max_run=5))
    return path, bytes(logical)


def expanded_with_partition(logical: bytes, partitions: tuple, name: str, image: bytes) -> bytes:
    """Return the expanded image with the partition's extents holding `image`, then zeros."""
    expected = bytearray(logical)
    for item_name, _group, extents in partitions:
        if item_name != name:
            continue
        consumed = 0
        for offset, size, target_type in extents:
            if target_type == 0:
                piece = image[consumed : consumed + size]
                expected[offset : offset + size] = piece + bytes(size - len(piece))
            consumed += size
    return bytes(expected)


def expanded(path: Path) -> bytes:
    with path.open("rb") as stream:
        size = sparse.read_header(stream).logical_size
        return sparse.read_range(stream, 0, size)


def test_synthetic_super_reads_back_with_the_reader(tmp_path: Path) -> None:
    """The fixture is a valid stock-like super before any writer runs."""
    path, logical = make_super(tmp_path)
    assert expanded(path) == logical
    with path.open("rb") as stream:
        metadata = lp.read_dynamic_partitions(stream, sparse=True)
    assert metadata is not None
    vendor = next(item for item in metadata.logical_partitions if item.name == "vendor_a")
    assert vendor.size == VENDOR_SIZE
    assert len(vendor.extents) == 2


def test_identity_rewrite_reproduces_the_super_bytes(tmp_path: Path) -> None:
    """Writing every chunk again with no replacement gives back the same bytes."""
    path, _logical = make_super(tmp_path)
    original = path.read_bytes()
    out = io.BytesIO()
    chunks = rewrite_ranges(io.BytesIO(original), out, [])
    assert out.getvalue() == original
    assert chunks == sparse.read_header(io.BytesIO(original)).total_chunks


def test_vendor_replacement_reads_back_and_keeps_everything_else(tmp_path: Path) -> None:
    """A new image that spans both vendor extents reads back, and the rest is unchanged."""
    source, logical = make_super(tmp_path)
    image = make_content(700 * KIB, seed=77)[:-100]
    image_path = tmp_path / "vendor_a.img"
    image_path.write_bytes(image)
    destination = tmp_path / "out.img"

    result = replace_partition(source, "vendor_a", image_path, destination)

    assert result.image_size == len(image)
    assert result.partition_size == VENDOR_SIZE
    assert result.physical_ranges == 2
    assert result.metadata_copies_checked == 2 + 2 * SLOT_COUNT
    assert result.partitions_compared == 2
    assert expanded(destination) == expanded_with_partition(logical, STOCK_LIKE, "vendor_a", image)
    assert not list(tmp_path.glob(".out.img.partial"))


def test_smaller_image_is_padded_with_zeros_to_the_partition(tmp_path: Path) -> None:
    """An image shorter than the partition leaves the rest of the partition zero."""
    source, logical = make_super(tmp_path)
    image = b"\x5a" * 100
    image_path = tmp_path / "small.img"
    image_path.write_bytes(image)
    destination = tmp_path / "small-out.img"

    replace_partition(source, "vendor_a", image_path, destination)

    expected = expanded_with_partition(logical, STOCK_LIKE, "vendor_a", image)
    assert expanded(destination) == expected
    with destination.open("rb") as stream:
        metadata = lp.read_dynamic_partitions(stream, sparse=True)
        vendor = next(item for item in metadata.logical_partitions if item.name == "vendor_a")
        content = lp.read_partition_range(stream, vendor, 0, vendor.size, sparse=True)
    assert content == image + bytes(VENDOR_SIZE - len(image))


def test_larger_image_is_refused_with_its_limit_and_no_output(tmp_path: Path) -> None:
    """An image larger than its partition is a typed error, and no output is left behind."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "big.img"
    image_path.write_bytes(bytes(VENDOR_SIZE + 1))
    destination = tmp_path / "big-out.img"

    with pytest.raises(PartitionTooLargeError) as caught:
        replace_partition(source, "vendor_a", image_path, destination)

    assert caught.value.image_size == VENDOR_SIZE + 1
    assert caught.value.partition_size == VENDOR_SIZE
    assert not destination.exists()
    assert not list(tmp_path.glob(".big-out.img.partial"))


def test_partition_without_extents_refuses_any_image(tmp_path: Path) -> None:
    """A partition with no extents (the B slot of a single-slot image) cannot hold data."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "one.img"
    image_path.write_bytes(b"x")

    with pytest.raises(PartitionTooLargeError) as caught:
        replace_partition(source, "vendor_b", image_path, tmp_path / "one-out.img")

    assert caught.value.partition_size == 0


def test_unknown_partition_and_existing_destination_are_refused(tmp_path: Path) -> None:
    """A missing partition name and an existing output are refused before anything is written."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpWriteError, match="no such logical partition"):
        replace_partition(source, "missing_a", image_path, tmp_path / "missing-out.img")

    existing = tmp_path / "existing.img"
    existing.write_bytes(b"keep")
    with pytest.raises(LpWriteError, match="already exists"):
        replace_partition(source, "vendor_a", image_path, existing)
    assert existing.read_bytes() == b"keep"


def test_output_must_not_be_the_source(tmp_path: Path) -> None:
    """The writer never writes over the super image that it reads."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpWriteError, match="must not be the super image"):
        replace_partition(source, "vendor_a", image_path, source)


def test_raw_super_image_is_refused(tmp_path: Path) -> None:
    """Only the sparse form that the manifest records is written."""
    _source, logical = make_super(tmp_path)
    raw = tmp_path / "raw.img"
    raw.write_bytes(logical)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpWriteError, match="not a sparse image"):
        replace_partition(raw, "vendor_a", image_path, tmp_path / "raw-out.img")


def test_non_linear_extent_is_refused(tmp_path: Path) -> None:
    """A zero-filled extent has no backing bytes, so data cannot be written to it."""
    partitions = (
        ("product_a", 1, ((2 * MIB, 256 * KIB, 0),)),
        ("vendor_a", 3, ((3 * MIB, 512 * KIB, 1),)),
    )
    source, _logical = make_super(tmp_path, partitions)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpWriteError, match="not linear"):
        replace_partition(source, "vendor_a", image_path, tmp_path / "zero-out.img")


def test_extent_that_is_not_block_aligned_is_refused(tmp_path: Path) -> None:
    """An extent that starts inside a sparse block cannot be rewritten by whole blocks."""
    partitions = (("vendor_a", 3, ((3 * MIB + 512, 512 * KIB - 512, 0),)),)
    source, _logical = make_super(tmp_path, partitions)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpWriteError, match="not aligned"):
        replace_partition(source, "vendor_a", image_path, tmp_path / "unaligned-out.img")


def test_corrupt_backup_metadata_is_refused_and_no_output_is_published(tmp_path: Path) -> None:
    """A checksum error in a backup copy stops the write before the output is published."""
    backup_slot_1 = lp.METADATA_START + SLOT_COUNT * METADATA_MAX + METADATA_MAX + 300
    source, _logical = make_super(tmp_path, corrupt=backup_slot_1)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    destination = tmp_path / "backup-out.img"

    with pytest.raises(LpMetadataError):
        replace_partition(source, "vendor_a", image_path, destination)

    assert not destination.exists()
    assert not list(tmp_path.glob(".backup-out.img.partial"))


def test_checksums_of_every_copy_are_counted(tmp_path: Path) -> None:
    """All geometry copies and all metadata copies of the synthetic super verify."""
    path, _logical = make_super(tmp_path)
    with path.open("rb") as stream:
        assert check_copies(stream) == 2 + 2 * SLOT_COUNT


def test_damaged_magic_in_a_backup_slot_is_refused_not_skipped(tmp_path: Path) -> None:
    """A slot that is not all zero must parse, so a damaged magic is refused, not skipped."""
    backup_slot_2 = lp.METADATA_START + SLOT_COUNT * METADATA_MAX + 2 * METADATA_MAX
    path, _logical = make_super(tmp_path, corrupt=backup_slot_2)
    with path.open("rb") as stream, pytest.raises(LpMetadataError):
        check_copies(stream)

    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpMetadataError):
        replace_partition(path, "vendor_a", image_path, tmp_path / "magic-out.img")
    assert not list(tmp_path.glob(".magic-out.img.partial"))


def test_output_that_appears_during_the_write_is_not_overwritten(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The output is linked into place, so a file that appears during the write is kept."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    destination = tmp_path / "late-out.img"
    real_rewrite = lp_write.rewrite_ranges

    def appearing(stream: io.BufferedIOBase, out: io.BufferedIOBase, replacements: list) -> int:
        destination.write_bytes(b"written by someone else")
        return real_rewrite(stream, out, replacements)

    monkeypatch.setattr(lp_write, "rewrite_ranges", appearing)
    with pytest.raises(LpWriteError, match="already exists"):
        replace_partition(source, "vendor_a", image_path, destination)

    assert destination.read_bytes() == b"written by someone else"
    assert not list(tmp_path.glob(".late-out.img.partial"))


def test_partial_name_that_is_an_input_is_refused_and_left_alone(tmp_path: Path) -> None:
    """The partial name of an output is never deleted when it names an input."""
    source, _logical = make_super(tmp_path, name=".out.img.partial")
    before = source.read_bytes()
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")

    with pytest.raises(LpWriteError, match="partial name is an input"):
        replace_partition(source, "vendor_a", image_path, tmp_path / "out.img")

    assert source.read_bytes() == before


def _tampered_writer(
    monkeypatch: pytest.MonkeyPatch, extra: list[RangeReplacement] | None, image_bytes: bytes | None
) -> None:
    """Make the rewrite change the output, so that the post-write checks must refuse it."""
    real_rewrite = lp_write.rewrite_ranges

    def tampered(stream: io.BufferedIOBase, out: io.BufferedIOBase, replacements: list) -> int:
        changed = list(replacements)
        if image_bytes is not None:
            flipped = io.BytesIO(image_bytes)
            changed = [dataclasses.replace(item, source=flipped) for item in changed]
        changed.extend(extra or [])
        return real_rewrite(stream, out, changed)

    monkeypatch.setattr(lp_write, "rewrite_ranges", tampered)


def test_post_write_check_refuses_a_partition_image_that_differs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The written partition must hold the image, so a changed byte of the image is refused."""
    source, _logical = make_super(tmp_path)
    image = make_content(700 * KIB, seed=5)[:-100]
    image_path = tmp_path / "image.img"
    image_path.write_bytes(image)
    _tampered_writer(monkeypatch, None, bytes([image[0] ^ 0xFF]) + image[1:])
    destination = tmp_path / "differs-out.img"

    with pytest.raises(LpWriteError, match="differs from the image"):
        replace_partition(source, "vendor_a", image_path, destination)
    assert not destination.exists()
    assert not list(tmp_path.glob(".differs-out.img.partial"))


def test_post_write_check_refuses_a_changed_other_partition(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A partition other than the target must read back unchanged, so a change there is refused."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    extra = RangeReplacement(
        offset=2 * MIB - BLOCK,
        size=BLOCK,
        source=io.BytesIO(b"\xab" * BLOCK),
        source_offset=0,
        source_size=BLOCK,
    )
    _tampered_writer(monkeypatch, [extra], None)
    destination = tmp_path / "other-out.img"

    with pytest.raises(LpWriteError, match="its data changed"):
        replace_partition(source, "vendor_a", image_path, destination)
    assert not destination.exists()


def test_post_write_check_refuses_changed_metadata(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The metadata region must stay byte-identical, so a change to the backup geometry fails."""
    source, _logical = make_super(tmp_path)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    extra = RangeReplacement(
        offset=lp.GEOMETRY_OFFSET + lp.GEOMETRY_SIZE,
        size=BLOCK,
        source=io.BytesIO(bytes(BLOCK)),
        source_offset=0,
        source_size=BLOCK,
    )
    _tampered_writer(monkeypatch, [extra], None)
    destination = tmp_path / "metadata-out.img"

    with pytest.raises(LpWriteError, match="metadata bytes differ"):
        replace_partition(source, "vendor_a", image_path, destination)
    assert not destination.exists()


def test_corrupt_primary_geometry_is_refused(tmp_path: Path) -> None:
    """The geometry check runs before any byte is written."""
    path, _logical = make_super(tmp_path, corrupt=lp.GEOMETRY_OFFSET + 45)
    image_path = tmp_path / "image.img"
    image_path.write_bytes(b"abc")
    with pytest.raises(LpMetadataError):
        replace_partition(path, "vendor_a", image_path, tmp_path / "geometry-out.img")


def test_real_stock_super_round_trips_when_a_path_is_given() -> None:
    """Gated: the stock super from APKRUN_LP_STOCK_SUPER round-trips without a change."""
    raw_path = os.environ.get("APKRUN_LP_STOCK_SUPER")
    if not raw_path:
        pytest.skip("set APKRUN_LP_STOCK_SUPER to the stock sparse super.img")
    path = Path(raw_path)
    original = path.read_bytes()
    out = io.BytesIO()
    rewrite_ranges(io.BytesIO(original), out, [])
    assert out.getvalue() == original
