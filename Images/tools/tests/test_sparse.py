"""Tests for sparse image parsing and bounded unsparsing."""

from __future__ import annotations

import io
import struct
import zlib

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
    iter_chunks,
    read_header,
    read_range,
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
