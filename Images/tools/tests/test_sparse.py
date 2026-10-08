"""Tests for sparse image parsing and bounded unsparsing."""

from __future__ import annotations

import hashlib
import io
import struct
import zlib
from pathlib import Path

import pytest

import apkrun_image.sparse as sparse_module
from apkrun_image.sparse import (
    CHUNK_CRC32,
    CHUNK_DONT_CARE,
    CHUNK_FILL,
    CHUNK_RAW,
    SPARSE_MAGIC,
    SparseImageError,
    _update_repeated,
    expand_into,
    iter_chunks,
    read_header,
    read_range,
    read_ranges,
    validate,
)


def sparse_fixture() -> tuple[bytes, bytes]:
    """Build a compact image containing every Android sparse chunk kind."""
    expanded = b"ABCD" + b"efgh" + b"\0" * 4
    chunks = [
        struct.pack("<HHII", CHUNK_RAW, 0, 1, 16) + b"ABCD",
        struct.pack("<HHII", CHUNK_FILL, 0, 1, 16) + b"efgh",
        struct.pack("<HHII", CHUNK_DONT_CARE, 0, 1, 12),
        struct.pack("<HHII", CHUNK_CRC32, 0, 0, 16) + struct.pack("<I", zlib.crc32(expanded)),
    ]
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        4,
        3,
        len(chunks),
        zlib.crc32(expanded),
    )
    return header + b"".join(chunks), expanded


def test_sparse_header_and_chunks_cover_every_type() -> None:
    """All four chunk types are parsed and the checksums are verified."""
    raw, expanded = sparse_fixture()
    stream = io.BytesIO(raw)
    header = read_header(stream)

    chunks = list(iter_chunks(stream, header))

    assert header.logical_size == len(expanded)
    assert [chunk.chunk_type for chunk in chunks] == [
        CHUNK_RAW,
        CHUNK_FILL,
        CHUNK_DONT_CARE,
        CHUNK_CRC32,
    ]


def test_sparse_range_expands_raw_fill_and_dont_care_chunks() -> None:
    """A small logical range is reconstructed without writing an image file."""
    raw, expanded = sparse_fixture()

    assert read_range(io.BytesIO(raw), 0, len(expanded)) == expanded
    assert read_range(io.BytesIO(raw), 2, 8) == expanded[2:10]


def test_sparse_ranges_merge_overlaps_and_read_in_one_pass() -> None:
    """Multiple requested ranges preserve caller order across sparse chunk types."""
    raw, expanded = sparse_fixture()
    ranges = [(2, 8), (0, 4), (12, 0), (4, 8), (1, 3)]

    assert read_ranges(io.BytesIO(raw), ranges) == [
        expanded[2:10],
        expanded[0:4],
        b"",
        expanded[4:12],
        expanded[1:4],
    ]


@pytest.mark.parametrize(
    ("seed", "pattern", "size"),
    [
        (0, b"\0", 0),
        (0, b"\0", 17),
        (0x12345678, b"ABCD", 37),
        (0xFFFFFFFF, b"\x01\x02\x03", 4097),
    ],
)
def test_repeated_crc_matches_zlib(seed: int, pattern: bytes, size: int) -> None:
    """Exponentiated CRC combination matches zlib for repeated data and prior state."""
    expanded = (pattern * ((size + len(pattern) - 1) // len(pattern)))[:size]

    assert _update_repeated(seed, pattern, size) == zlib.crc32(expanded, seed)


def test_repeated_crc_work_is_logarithmic_for_maximum_sparse_image(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A valid 64 GiB don't-care chunk performs constant CRC calls."""
    original_crc32 = sparse_module.zlib.crc32
    calls = 0

    def count_crc32(data: bytes, value: int = 0) -> int:
        nonlocal calls
        calls += 1
        return original_crc32(data, value)

    monkeypatch.setattr(sparse_module.zlib, "crc32", count_crc32)
    result = _update_repeated(0, b"\0", 64 * 1024 * 1024 * 1024)

    assert 0 <= result <= 0xFFFFFFFF
    assert calls <= 2


def test_sparse_validation_rejects_checksum_mismatch() -> None:
    """A corrupt CRC32 chunk is rejected."""
    raw, _expanded = sparse_fixture()
    corrupted = bytearray(raw)
    corrupted[-1] ^= 0x01

    with pytest.raises(SparseImageError, match="CRC32 sparse chunk"):
        validate(io.BytesIO(corrupted))


def test_sparse_validation_rejects_total_block_mismatch() -> None:
    """The chunk expansion must equal the header's logical block count."""
    raw, _expanded = sparse_fixture()
    corrupted = bytearray(raw)
    struct.pack_into("<I", corrupted, 16, 4)

    with pytest.raises(SparseImageError, match="describe"):
        validate(io.BytesIO(corrupted))


def test_sparse_validation_rejects_oversized_chunk_before_expanding() -> None:
    """A tiny malicious chunk cannot trigger a huge don't-care CRC loop."""
    chunk = struct.pack("<HHII", CHUNK_DONT_CARE, 0, 0xFFFFFFFF, 12)
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        0xFFFFFFFC,
        1,
        1,
        0,
    )

    with pytest.raises(SparseImageError, match="exceeds the declared output"):
        validate(io.BytesIO(header + chunk))


def test_sparse_range_rejects_oversized_chunk_before_expanding() -> None:
    """Range reads check declared block bounds before generating output bytes."""
    chunk = struct.pack("<HHII", CHUNK_DONT_CARE, 0, 0xFFFFFFFF, 12)
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        0xFFFFFFFC,
        1,
        1,
        0,
    )

    with pytest.raises(SparseImageError, match="exceeds the declared output"):
        read_range(io.BytesIO(header + chunk), 0, 1)


def test_sparse_header_rejects_unbounded_declared_output() -> None:
    """A tiny sparse header cannot request CRC work over an enormous logical image."""
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        0xFFFFFFFC,
        0xFFFFFFFF,
        0,
        0,
    )

    with pytest.raises(SparseImageError, match="64 GiB logical-size limit"):
        read_header(io.BytesIO(header))


EXPECTED_SHA256 = Path(__file__).parent / "fixtures/sparse/expected-sha256.txt"
FIXTURE_IMAGES = Path(__file__).parent / "fixtures/images"


def _simg2img_hashes() -> dict[str, str]:
    hashes: dict[str, str] = {}
    for line in EXPECTED_SHA256.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            digest, name = line.split()
            hashes[name] = digest
    return hashes


def test_expand_into_writes_the_expanded_image_at_an_offset() -> None:
    raw, expanded = sparse_fixture()
    out = io.BytesIO(bytes(8 + len(expanded)))

    header = expand_into(io.BytesIO(raw), out, 8)

    assert header.logical_size == len(expanded)
    assert out.getvalue() == bytes(8) + expanded


@pytest.mark.parametrize("name", ["super.img", "userdata.img", "sparse-all-chunks.img"])
def test_expand_into_matches_simg2img(name: str, tmp_path: Path) -> None:
    source = FIXTURE_IMAGES / name
    output = tmp_path / "expanded.raw"
    with source.open("rb") as stream:
        size = read_header(stream).logical_size
    with source.open("rb") as stream, output.open("w+b") as out:
        out.truncate(size)
        expand_into(stream, out, 0)

    assert hashlib.sha256(output.read_bytes()).hexdigest() == _simg2img_hashes()[name]


def test_expand_into_leaves_dont_care_and_zero_fill_as_holes(tmp_path: Path) -> None:
    block = 4096
    blocks = 16384  # 64 MiB: APFS allocates small files in full instead of leaving holes
    chunks = [
        struct.pack("<HHII", CHUNK_RAW, 0, 1, 12 + block) + b"x" * block,
        struct.pack("<HHII", CHUNK_DONT_CARE, 0, blocks // 2, 12),
        struct.pack("<HHII", CHUNK_FILL, 0, blocks // 2 - 1, 16) + b"\0\0\0\0",
    ]
    header = struct.pack("<I4H4I", SPARSE_MAGIC, 1, 0, 28, 12, block, blocks, len(chunks), 0)
    output = tmp_path / "holes.raw"
    with output.open("w+b") as out:
        out.truncate(block * blocks)
        expand_into(io.BytesIO(header + b"".join(chunks)), out, 0)

    assert output.stat().st_size == block * blocks
    assert output.stat().st_blocks * 512 < block * blocks // 4
    with output.open("rb") as stream:
        assert stream.read(block) == b"x" * block
        assert stream.read(block) == bytes(block)


def test_expand_into_rejects_a_crc_mismatch() -> None:
    raw, _expanded = sparse_fixture()
    corrupted = bytearray(raw)
    corrupted[-1] ^= 0xFF
    with pytest.raises(SparseImageError, match="CRC32 sparse chunk 3 mismatch"):
        expand_into(io.BytesIO(bytes(corrupted)), io.BytesIO(bytes(64)), 0)


def test_expand_into_rejects_a_truncated_image() -> None:
    raw, _expanded = sparse_fixture()
    with pytest.raises(SparseImageError, match="truncated"):
        expand_into(io.BytesIO(raw[:40]), io.BytesIO(bytes(64)), 0)
