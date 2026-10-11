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
    RangeReplacement,
    SparseImageError,
    _update_repeated,
    expand_into,
    iter_chunks,
    read_header,
    read_range,
    read_ranges,
    rewrite_ranges,
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


def test_zero_blocks_stay_holes_and_the_bytes_read_back(tmp_path: Path) -> None:
    """A zero run is not allocated on disk, and the output reads back the same bytes (§4.3).

    The file extends past the written range. APFS allocates the extent nearest the end of a
    file when a write lands in it, so the test keeps the zero run away from the end.
    """
    from apkrun_image.sparse import write_skipping_zeros

    megabyte = 1024 * 1024
    target = tmp_path / "os.img"
    start = 16 * megabyte
    payload = b"\x05" * 4096 + bytes(8 * megabyte)
    size = 64 * megabyte
    with target.open("w+b") as out:
        out.truncate(size)
        write_skipping_zeros(out, start, payload)
    status = target.stat()
    assert status.st_size == size
    assert status.st_blocks * 512 < megabyte, "the 8 MiB zero run was allocated"
    data = target.read_bytes()
    assert data[start : start + 4096] == b"\x05" * 4096
    assert data[start + 4096 : start + len(payload)] == bytes(8 * megabyte)
    assert data[start + len(payload) :] == bytes(size - start - len(payload))


BLOCK = 4


def block_sparse(*chunks: tuple[int, int, bytes | None]) -> tuple[bytes, bytes]:
    """Build a sparse image of 4-byte blocks from (type, block count, payload) and its expansion."""
    records = []
    expanded = bytearray()
    for chunk_type, count, payload in chunks:
        if chunk_type == CHUNK_RAW:
            assert payload is not None and len(payload) == count * BLOCK
            records.append(struct.pack("<HHII", chunk_type, 0, count, 12 + len(payload)) + payload)
            expanded += payload
        elif chunk_type == CHUNK_FILL:
            assert payload is not None and len(payload) == 4
            records.append(struct.pack("<HHII", chunk_type, 0, count, 16) + payload)
            expanded += payload * count
        else:
            records.append(struct.pack("<HHII", CHUNK_DONT_CARE, 0, count, 12))
            expanded += bytes(count * BLOCK)
    header = struct.pack(
        "<I4H4I", SPARSE_MAGIC, 1, 0, 28, 12, BLOCK, len(expanded) // BLOCK, len(records), 0
    )
    return header + b"".join(records), bytes(expanded)


def rewritten(raw: bytes, replacements: list) -> bytes:
    """Rewrite a sparse image and return the output bytes."""
    out = io.BytesIO()
    rewrite_ranges(io.BytesIO(raw), out, replacements)
    return out.getvalue()


def expanded_of(raw: bytes) -> bytes:
    """Return the expanded bytes of a sparse image."""
    stream = io.BytesIO(raw)
    return read_range(stream, 0, read_header(stream).logical_size)


def test_rewrite_without_replacements_gives_back_the_input_bytes() -> None:
    """Each chunk is written from its parsed record, so an unchanged image is identical."""
    raw, expanded = block_sparse(
        (CHUNK_RAW, 2, b"A" * 8),
        (CHUNK_FILL, 3, b"efgh"),
        (CHUNK_DONT_CARE, 2, None),
        (CHUNK_RAW, 1, b"zzzz"),
    )
    out = io.BytesIO()
    chunks = rewrite_ranges(io.BytesIO(raw), out, [])
    assert out.getvalue() == raw
    assert chunks == 4
    assert expanded_of(raw) == expanded


def test_replacement_splits_chunks_on_both_sides_and_keeps_their_types() -> None:
    """A range that starts inside a FILL chunk and ends inside a RAW chunk cuts both of them."""
    raw, expanded = block_sparse(
        (CHUNK_FILL, 4, b"efgh"),
        (CHUNK_RAW, 3, b"1111" + b"2222" + b"3333"),
        (CHUNK_DONT_CARE, 2, None),
    )
    new = b"NEWN" * 4
    replacement = RangeReplacement(
        offset=2 * BLOCK,
        size=4 * BLOCK,
        source=io.BytesIO(new),
        source_offset=0,
        source_size=len(new),
    )
    result = rewritten(raw, [replacement])
    assert expanded_of(result) == expanded[: 2 * BLOCK] + new + expanded[6 * BLOCK :]
    chunks = list(iter_chunks(io.BytesIO(result)))
    assert chunks[0].chunk_type == CHUNK_FILL, "the FILL piece before the cut keeps its type"
    assert chunks[0].block_count == 2
    assert chunks[0].fill_pattern == b"efgh"
    assert chunks[-2].chunk_type == CHUNK_RAW, "the RAW piece after the cut keeps its type"
    assert chunks[-2].block_count == 1
    assert chunks[-1].chunk_type == CHUNK_DONT_CARE


def test_replacement_encodes_zero_blocks_as_dont_care_and_splits_long_raw_runs() -> None:
    """Zero blocks become DONT_CARE; a run of non-zero blocks is cut into RAW runs of 256 blocks."""
    raw, _expanded = block_sparse((CHUNK_DONT_CARE, 602, None))
    data = bytes(BLOCK) + b"".join(bytes([1 + index % 200]) * BLOCK for index in range(600))
    data += bytes(BLOCK)
    replacement = RangeReplacement(
        offset=0,
        size=len(data),
        source=io.BytesIO(data),
        source_offset=0,
        source_size=len(data),
    )
    out = io.BytesIO()
    chunk_count = rewrite_ranges(io.BytesIO(raw), out, [replacement])
    assert expanded_of(out.getvalue()) == data
    chunks = list(iter_chunks(io.BytesIO(out.getvalue())))
    assert chunk_count == len(chunks) == 5
    assert [(chunk.chunk_type, chunk.block_count) for chunk in chunks] == [
        (CHUNK_DONT_CARE, 1),
        (CHUNK_RAW, 256),
        (CHUNK_RAW, 256),
        (CHUNK_RAW, 88),
        (CHUNK_DONT_CARE, 1),
    ]


def test_short_replacement_source_is_padded_with_zeros() -> None:
    """Bytes past the source are zero, including the rest of a partial last block."""
    raw, expanded = block_sparse((CHUNK_FILL, 3, b"abcd"))
    replacement = RangeReplacement(
        offset=BLOCK,
        size=2 * BLOCK,
        source=io.BytesIO(b"xyz"),
        source_offset=0,
        source_size=3,
    )
    result = rewritten(raw, [replacement])
    assert (
        expanded_of(result)
        == expanded[:BLOCK] + b"xyz" + bytes(2 * BLOCK - 3) + expanded[3 * BLOCK :]
    )


@pytest.mark.parametrize(
    ("replacement", "message"),
    [
        (RangeReplacement(offset=1, size=BLOCK), "not aligned"),
        (RangeReplacement(offset=0, size=3), "not aligned"),
        (RangeReplacement(offset=0, size=0), "must start at 0 or later"),
        (RangeReplacement(offset=3 * BLOCK, size=2 * BLOCK), "past the expanded image"),
        (
            RangeReplacement(
                offset=0, size=BLOCK, source=io.BytesIO(b"x" * 5), source_size=BLOCK + 1
            ),
            "exceeds the replacement size",
        ),
        (RangeReplacement(offset=0, size=BLOCK, source=None, source_size=1), "no source"),
    ],
)
def test_invalid_replacements_are_refused(replacement: RangeReplacement, message: str) -> None:
    """Ranges that are misaligned, empty, outside the image, or without their source are refused."""
    raw, _expanded = block_sparse((CHUNK_FILL, 3, b"abcd"))
    with pytest.raises(SparseImageError, match=message):
        rewritten(raw, [replacement])


def test_overlapping_replacements_are_refused() -> None:
    """Two ranges that share a block cannot both be written."""
    raw, _expanded = block_sparse((CHUNK_FILL, 3, b"abcd"))
    first = RangeReplacement(offset=0, size=2 * BLOCK)
    second = RangeReplacement(offset=BLOCK, size=BLOCK)
    with pytest.raises(SparseImageError, match="overlap"):
        rewritten(raw, [first, second])


def test_images_with_checksums_or_crc_chunks_are_refused() -> None:
    """A whole-image checksum or a CRC32 chunk would be stale after a rewrite, so both refuse."""
    raw, _expanded = sparse_fixture()
    with pytest.raises(SparseImageError, match="image checksum"):
        rewritten(raw, [])
    fill_then_crc = (
        struct.pack("<I4H4I", SPARSE_MAGIC, 1, 0, 28, 12, 4, 1, 2, 0)
        + struct.pack("<HHII", CHUNK_FILL, 0, 1, 16)
        + b"abcd"
        + struct.pack("<HHII", CHUNK_CRC32, 0, 0, 16)
        + struct.pack("<I", zlib.crc32(b"abcd"))
    )
    with pytest.raises(SparseImageError, match="CRC32"):
        rewritten(fill_then_crc, [])


def test_nonstandard_header_sizes_are_refused() -> None:
    """Only the standard 28-byte file header and 12-byte chunk headers are rewritten."""
    raw, _expanded = block_sparse((CHUNK_FILL, 1, b"abcd"))
    extended = raw[:8] + struct.pack("<H", 32) + raw[10:28] + bytes(4) + raw[28:]
    with pytest.raises(SparseImageError, match="standard sparse header sizes"):
        rewritten(extended, [])


def test_bytes_after_the_last_chunk_are_refused() -> None:
    """Bytes after the last chunk are not part of the image, and a rewrite would drop them."""
    raw, _expanded = block_sparse((CHUNK_FILL, 1, b"abcd"))
    with pytest.raises(SparseImageError, match="bytes follow the last sparse chunk"):
        rewritten(raw + b"xyz", [])
    assert rewritten(raw, []) == raw
