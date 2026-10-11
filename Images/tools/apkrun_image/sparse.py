"""Streaming reader and hole-preserving writer for the Android sparse image format."""

from __future__ import annotations

import struct
import zlib
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from typing import BinaryIO

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4
FILE_HEADER_SIZE = 28
CHUNK_HEADER_SIZE = 12
COPY_SIZE = 1024 * 1024
ZERO_BLOCK_BYTES = 4096
MAX_LOGICAL_SIZE = 64 * 1024 * 1024 * 1024


class SparseImageError(ValueError):
    """A malformed or unsupported Android sparse image."""


@dataclass(frozen=True)
class SparseHeader:
    """Parsed Android sparse image header."""

    major_version: int
    minor_version: int
    file_header_size: int
    chunk_header_size: int
    block_size: int
    total_blocks: int
    total_chunks: int
    image_checksum: int

    @property
    def logical_size(self) -> int:
        """Return the expanded image size in bytes."""
        return self.block_size * self.total_blocks


@dataclass(frozen=True)
class SparseChunk:
    """A sparse chunk's location in the source and expanded image."""

    chunk_type: int
    logical_offset: int
    block_count: int
    block_size: int
    payload_offset: int
    payload_size: int
    fill_pattern: bytes | None

    @property
    def logical_size(self) -> int:
        """Return this chunk's expanded size."""
        return self.block_count * self.block_size


def _read_exact(stream: BinaryIO, size: int, context: str) -> bytes:
    """Read exactly size bytes or reject a truncated image."""
    chunks: list[bytes] = []
    remaining = size
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            raise SparseImageError(f"truncated sparse image while reading {context}")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_header(stream: BinaryIO) -> SparseHeader:
    """Read and validate the sparse file header."""
    try:
        stream.seek(0)
    except (OSError, AttributeError) as error:
        raise SparseImageError("sparse image input must be seekable") from error
    raw = _read_exact(stream, FILE_HEADER_SIZE, "file header")
    (
        magic,
        major_version,
        minor_version,
        file_header_size,
        chunk_header_size,
        block_size,
        total_blocks,
        total_chunks,
        image_checksum,
    ) = struct.unpack("<I4H4I", raw)
    if magic != SPARSE_MAGIC:
        raise SparseImageError("invalid Android sparse image magic")
    if major_version != 1:
        raise SparseImageError(f"unsupported Android sparse image major version {major_version}")
    if file_header_size < FILE_HEADER_SIZE or chunk_header_size < CHUNK_HEADER_SIZE:
        raise SparseImageError("Android sparse image header size is smaller than its structure")
    if block_size < 4 or block_size % 4 != 0:
        raise SparseImageError(f"invalid Android sparse block size {block_size}")
    if block_size * total_blocks > MAX_LOGICAL_SIZE:
        raise SparseImageError(
            "Android sparse image exceeds the parser's 64 GiB logical-size limit"
        )
    if total_blocks == 0 and total_chunks != 0:
        raise SparseImageError("Android sparse image has chunks but no output blocks")
    if file_header_size > FILE_HEADER_SIZE:
        _read_exact(stream, file_header_size - FILE_HEADER_SIZE, "file header extension")
    return SparseHeader(
        major_version=major_version,
        minor_version=minor_version,
        file_header_size=file_header_size,
        chunk_header_size=chunk_header_size,
        block_size=block_size,
        total_blocks=total_blocks,
        total_chunks=total_chunks,
        image_checksum=image_checksum,
    )


def _gf2_matrix_times(matrix: list[int], vector: int) -> int:
    """Multiply a CRC polynomial vector by a GF(2) matrix."""
    result = 0
    index = 0
    while vector:
        if vector & 1:
            result ^= matrix[index]
        vector >>= 1
        index += 1
    return result


def _gf2_matrix_square(matrix: list[int]) -> list[int]:
    """Square a CRC polynomial matrix."""
    return [_gf2_matrix_times(matrix, value) for value in matrix]


def _crc32_combine(first: int, second: int, second_size: int) -> int:
    """Combine two standard CRC-32 values as if their byte strings were concatenated."""
    if second_size <= 0:
        return first

    odd = [0] * 32
    odd[0] = 0xEDB88320
    row = 1
    for index in range(1, 32):
        odd[index] = row
        row <<= 1
    even = _gf2_matrix_square(odd)
    odd = _gf2_matrix_square(even)

    while True:
        even = _gf2_matrix_square(odd)
        if second_size & 1:
            first = _gf2_matrix_times(even, first)
        second_size >>= 1
        if second_size == 0:
            break
        odd = _gf2_matrix_square(even)
        if second_size & 1:
            first = _gf2_matrix_times(odd, first)
        second_size >>= 1

    return first ^ second


def _update_repeated(crc: int, pattern: bytes, size: int) -> int:
    """Update a CRC over repeated bytes in logarithmic time and constant memory."""
    if not pattern:
        raise SparseImageError("empty Android sparse fill pattern")
    if size <= 0:
        return crc

    repeats, remainder = divmod(size, len(pattern))
    repeat_crc = zlib.crc32(pattern)
    repeat_size = len(pattern)
    combined_crc = 0
    while repeats:
        if repeats & 1:
            combined_crc = _crc32_combine(combined_crc, repeat_crc, repeat_size)
        repeats >>= 1
        if repeats:
            repeat_crc = _crc32_combine(repeat_crc, repeat_crc, repeat_size)
            repeat_size *= 2

    combined_size = size - remainder
    if remainder:
        tail = pattern[:remainder]
        combined_crc = _crc32_combine(combined_crc, zlib.crc32(tail), len(tail))
        combined_size += remainder
    return _crc32_combine(crc, combined_crc, combined_size)


def iter_chunks(stream: BinaryIO, header: SparseHeader | None = None) -> Iterator[SparseChunk]:
    """Validate and yield all sparse chunks while checking both checksum forms."""
    parsed_header = header or read_header(stream)
    logical_offset = 0
    running_crc = 0
    for index in range(parsed_header.total_chunks):
        raw_header = _read_exact(stream, parsed_header.chunk_header_size, f"chunk {index} header")
        chunk_type, reserved, block_count, total_size = struct.unpack_from("<HHII", raw_header)
        if reserved != 0:
            raise SparseImageError(f"sparse chunk {index} has nonzero reserved bits")
        payload_size = total_size - parsed_header.chunk_header_size
        if payload_size < 0:
            raise SparseImageError(f"sparse chunk {index} has an invalid total size")
        payload_offset = stream.tell()
        logical_size = block_count * parsed_header.block_size
        fill_pattern: bytes | None = None

        if chunk_type != CHUNK_CRC32:
            completed_blocks = logical_offset // parsed_header.block_size
            if block_count > parsed_header.total_blocks - completed_blocks:
                raise SparseImageError(
                    f"sparse chunk {index} exceeds the declared output block count"
                )

        if chunk_type == CHUNK_RAW:
            if payload_size != logical_size:
                raise SparseImageError(f"raw sparse chunk {index} has an invalid payload size")
            remaining = payload_size
            while remaining:
                chunk = _read_exact(stream, min(remaining, COPY_SIZE), f"raw chunk {index}")
                running_crc = zlib.crc32(chunk, running_crc)
                remaining -= len(chunk)
        elif chunk_type == CHUNK_FILL:
            if block_count == 0 or payload_size != 4:
                raise SparseImageError(f"fill sparse chunk {index} has an invalid size")
            fill_pattern = _read_exact(stream, 4, f"fill pattern for chunk {index}")
            running_crc = _update_repeated(running_crc, fill_pattern, logical_size)
        elif chunk_type == CHUNK_DONT_CARE:
            if payload_size != 0:
                raise SparseImageError(f"don't-care sparse chunk {index} has a payload")
            running_crc = _update_repeated(running_crc, b"\0", logical_size)
        elif chunk_type == CHUNK_CRC32:
            if block_count != 0 or payload_size != 4:
                raise SparseImageError(f"CRC32 sparse chunk {index} has an invalid size")
            expected_crc = struct.unpack("<I", _read_exact(stream, 4, f"CRC32 chunk {index}"))[0]
            if expected_crc != running_crc:
                raise SparseImageError(
                    f"CRC32 sparse chunk {index} mismatch "
                    f"(expected {expected_crc:08x}, calculated {running_crc:08x})"
                )
        else:
            raise SparseImageError(f"unsupported Android sparse chunk type 0x{chunk_type:04x}")

        if chunk_type != CHUNK_CRC32:
            logical_offset += logical_size
        yield SparseChunk(
            chunk_type=chunk_type,
            logical_offset=logical_offset - logical_size
            if chunk_type != CHUNK_CRC32
            else logical_offset,
            block_count=block_count,
            block_size=parsed_header.block_size,
            payload_offset=payload_offset,
            payload_size=payload_size,
            fill_pattern=fill_pattern,
        )

    if logical_offset != parsed_header.logical_size:
        raise SparseImageError(
            f"sparse chunks describe {logical_offset} bytes, expected {parsed_header.logical_size}"
        )
    if parsed_header.image_checksum and parsed_header.image_checksum != running_crc:
        raise SparseImageError(
            f"sparse image checksum mismatch "
            f"(expected {parsed_header.image_checksum:08x}, calculated {running_crc:08x})"
        )


def write_skipping_zeros(out: BinaryIO, position: int, data: bytes) -> None:
    """Write `data` at `position`, leaving every all-zero block as a hole.

    Zero bytes that the image carries as RAW data would otherwise be allocated on disk. The
    output is the same bytes either way (android-image.md §4.3, §10.2), and a hole reads as zeros.
    """
    for start in range(0, len(data), ZERO_BLOCK_BYTES):
        block = data[start : start + ZERO_BLOCK_BYTES]
        if block.strip(b"\0"):
            out.seek(position + start)
            out.write(block)


def expand_into(stream: BinaryIO, out: BinaryIO, offset: int) -> SparseHeader:
    """Write the expanded image into `out` at `offset`, leaving zero ranges as holes.

    Non-zero blocks of RAW chunks and FILL chunks with a non-zero pattern are
    written. Zero blocks, DONT_CARE chunks, and zero FILL chunks are skipped, so on
    a sparse-capable file system they stay unallocated (android-image.md §4.3). The caller sizes
    `out` beforehand. Both checksum forms are verified as the stream is read;
    a mismatch raises after the bytes before it were written, so callers must
    discard the output on error.
    """
    header = read_header(stream)
    logical_offset = 0
    running_crc = 0
    zero_pattern = b"\0\0\0\0"
    for index in range(header.total_chunks):
        raw_header = _read_exact(stream, header.chunk_header_size, f"chunk {index} header")
        chunk_type, reserved, block_count, total_size = struct.unpack_from("<HHII", raw_header)
        if reserved != 0:
            raise SparseImageError(f"sparse chunk {index} has nonzero reserved bits")
        payload_size = total_size - header.chunk_header_size
        if payload_size < 0:
            raise SparseImageError(f"sparse chunk {index} has an invalid total size")
        logical_size = block_count * header.block_size
        if chunk_type != CHUNK_CRC32 and logical_offset + logical_size > header.logical_size:
            raise SparseImageError(f"sparse chunk {index} exceeds the declared output block count")
        if chunk_type == CHUNK_RAW:
            if payload_size != logical_size:
                raise SparseImageError(f"raw sparse chunk {index} has an invalid payload size")
            position = offset + logical_offset
            remaining = payload_size
            while remaining:
                data = _read_exact(stream, min(remaining, COPY_SIZE), f"raw chunk {index}")
                running_crc = zlib.crc32(data, running_crc)
                write_skipping_zeros(out, position, data)
                position += len(data)
                remaining -= len(data)
        elif chunk_type == CHUNK_FILL:
            if block_count == 0 or payload_size != 4:
                raise SparseImageError(f"fill sparse chunk {index} has an invalid size")
            pattern = _read_exact(stream, 4, f"fill pattern for chunk {index}")
            running_crc = _update_repeated(running_crc, pattern, logical_size)
            if pattern != zero_pattern:
                out.seek(offset + logical_offset)
                block = pattern * (COPY_SIZE // 4)
                remaining = logical_size
                while remaining:
                    piece = block[: min(remaining, COPY_SIZE)]
                    out.write(piece)
                    remaining -= len(piece)
        elif chunk_type == CHUNK_DONT_CARE:
            if payload_size != 0:
                raise SparseImageError(f"don't-care sparse chunk {index} has a payload")
            running_crc = _update_repeated(running_crc, b"\0", logical_size)
        elif chunk_type == CHUNK_CRC32:
            if block_count != 0 or payload_size != 4:
                raise SparseImageError(f"CRC32 sparse chunk {index} has an invalid size")
            expected_crc = struct.unpack("<I", _read_exact(stream, 4, f"CRC32 chunk {index}"))[0]
            if expected_crc != running_crc:
                raise SparseImageError(
                    f"CRC32 sparse chunk {index} mismatch "
                    f"(expected {expected_crc:08x}, calculated {running_crc:08x})"
                )
            continue
        else:
            raise SparseImageError(f"unsupported Android sparse chunk type 0x{chunk_type:04x}")
        logical_offset += logical_size

    if logical_offset != header.logical_size:
        raise SparseImageError(
            f"sparse chunks describe {logical_offset} bytes, expected {header.logical_size}"
        )
    if header.image_checksum and header.image_checksum != running_crc:
        raise SparseImageError(
            f"sparse image checksum mismatch "
            f"(expected {header.image_checksum:08x}, calculated {running_crc:08x})"
        )
    return header


def validate(stream: BinaryIO) -> SparseHeader:
    """Validate the whole chunk stream and return its header."""
    header = read_header(stream)
    for _chunk in iter_chunks(stream, header):
        pass
    return header


def read_range(stream: BinaryIO, offset: int, size: int) -> bytes:
    """Read a bounded range from the expanded image without materializing it."""
    if offset < 0 or size < 0:
        raise SparseImageError("sparse image range cannot be negative")
    header = read_header(stream)
    if offset + size > header.logical_size:
        raise SparseImageError("sparse image range extends past the expanded image")
    if size == 0:
        return b""

    output = bytearray()
    requested_end = offset + size
    logical_offset = 0
    for index in range(header.total_chunks):
        raw_header = _read_exact(stream, header.chunk_header_size, f"chunk {index} header")
        chunk_type, reserved, block_count, total_size = struct.unpack_from("<HHII", raw_header)
        if reserved != 0:
            raise SparseImageError(f"sparse chunk {index} has nonzero reserved bits")
        payload_size = total_size - header.chunk_header_size
        if payload_size < 0:
            raise SparseImageError(f"sparse chunk {index} has an invalid total size")
        payload_offset = stream.tell()
        logical_size = block_count * header.block_size
        logical_end = logical_offset + logical_size
        if chunk_type != CHUNK_CRC32:
            completed_blocks = logical_offset // header.block_size
            if block_count > header.total_blocks - completed_blocks:
                raise SparseImageError(
                    f"sparse chunk {index} exceeds the declared output block count"
                )
        intersects = logical_size > 0 and logical_offset < requested_end and logical_end > offset

        if chunk_type == CHUNK_RAW:
            if payload_size != logical_size:
                raise SparseImageError(f"raw sparse chunk {index} has an invalid payload size")
            if intersects:
                start = max(offset, logical_offset) - logical_offset
                end = min(requested_end, logical_end) - logical_offset
                stream.seek(payload_offset + start)
                output.extend(_read_exact(stream, end - start, f"raw range in chunk {index}"))
            stream.seek(payload_offset + payload_size)
        elif chunk_type == CHUNK_FILL:
            if block_count == 0 or payload_size != 4:
                raise SparseImageError(f"fill sparse chunk {index} has an invalid size")
            pattern = _read_exact(stream, 4, f"fill pattern for chunk {index}")
            if intersects:
                start = max(offset, logical_offset) - logical_offset
                end = min(requested_end, logical_end) - logical_offset
                first_phase = start % 4
                repeated = pattern[first_phase:] + pattern * ((end - start) // 4 + 1)
                output.extend(repeated[: end - start])
        elif chunk_type == CHUNK_DONT_CARE:
            if payload_size != 0:
                raise SparseImageError(f"don't-care sparse chunk {index} has a payload")
            if intersects:
                start = max(offset, logical_offset)
                end = min(requested_end, logical_end)
                output.extend(b"\0" * (end - start))
        elif chunk_type == CHUNK_CRC32:
            if block_count != 0 or payload_size != 4:
                raise SparseImageError(f"CRC32 sparse chunk {index} has an invalid size")
            _read_exact(stream, 4, f"CRC32 chunk {index}")
            continue
        else:
            raise SparseImageError(f"unsupported Android sparse chunk type 0x{chunk_type:04x}")

        logical_offset = logical_end
        if len(output) == size:
            return bytes(output)

    raise SparseImageError(f"sparse chunks supplied {len(output)} of {size} requested bytes")


def read_ranges(stream: BinaryIO, ranges: Sequence[tuple[int, int]]) -> list[bytes]:
    """Read several expanded-image ranges in one forward pass."""
    header = read_header(stream)
    ordered: list[tuple[int, int, int]] = []
    for index, (offset, size) in enumerate(ranges):
        if offset < 0 or size < 0:
            raise SparseImageError("sparse image range cannot be negative")
        if offset > header.logical_size or size > header.logical_size - offset:
            raise SparseImageError("sparse image range extends past the expanded image")
        ordered.append((offset, offset + size, index))
    ordered.sort()

    merged: list[tuple[int, int]] = []
    request_segments: list[tuple[int, int | None, int]] = [
        (index, None, 0) for index in range(len(ranges))
    ]
    for start, end, index in ordered:
        if start == end:
            continue
        if not merged or start > merged[-1][1]:
            merged.append((start, end))
        else:
            previous_start, previous_end = merged[-1]
            merged[-1] = (previous_start, max(previous_end, end))
        segment_index = len(merged) - 1
        request_segments[index] = (index, segment_index, start - merged[segment_index][0])

    output = [bytearray() for _ in merged]
    segment_index = 0
    logical_offset = 0
    for chunk_index in range(header.total_chunks):
        raw_header = _read_exact(stream, header.chunk_header_size, f"chunk {chunk_index} header")
        chunk_type, reserved, block_count, total_size = struct.unpack_from("<HHII", raw_header)
        if reserved != 0:
            raise SparseImageError(f"sparse chunk {chunk_index} has nonzero reserved bits")
        payload_size = total_size - header.chunk_header_size
        if payload_size < 0:
            raise SparseImageError(f"sparse chunk {chunk_index} has an invalid total size")
        payload_offset = stream.tell()
        logical_size = block_count * header.block_size
        logical_end = logical_offset + logical_size
        if chunk_type != CHUNK_CRC32:
            completed_blocks = logical_offset // header.block_size
            if block_count > header.total_blocks - completed_blocks:
                raise SparseImageError(
                    f"sparse chunk {chunk_index} exceeds the declared output block count"
                )

        if chunk_type == CHUNK_RAW:
            if payload_size != logical_size:
                raise SparseImageError(
                    f"raw sparse chunk {chunk_index} has an invalid payload size"
                )
            while segment_index < len(merged) and merged[segment_index][0] < logical_end:
                start, end = merged[segment_index]
                overlap_start = max(start, logical_offset)
                overlap_end = min(end, logical_end)
                if overlap_start < overlap_end:
                    source_offset = payload_offset + overlap_start - logical_offset
                    stream.seek(source_offset)
                    output[segment_index].extend(
                        _read_exact(
                            stream,
                            overlap_end - overlap_start,
                            f"raw range in chunk {chunk_index}",
                        )
                    )
                if end <= logical_end:
                    segment_index += 1
                else:
                    break
            stream.seek(payload_offset + payload_size)
        elif chunk_type == CHUNK_FILL:
            if block_count == 0 or payload_size != 4:
                raise SparseImageError(f"fill sparse chunk {chunk_index} has an invalid size")
            pattern = _read_exact(stream, 4, f"fill pattern for chunk {chunk_index}")
            while segment_index < len(merged) and merged[segment_index][0] < logical_end:
                start, end = merged[segment_index]
                overlap_start = max(start, logical_offset)
                overlap_end = min(end, logical_end)
                if overlap_start < overlap_end:
                    phase = (overlap_start - logical_offset) % len(pattern)
                    repeated = pattern[phase:] + pattern * (
                        (overlap_end - overlap_start) // len(pattern) + 1
                    )
                    output[segment_index].extend(repeated[: overlap_end - overlap_start])
                if end <= logical_end:
                    segment_index += 1
                else:
                    break
        elif chunk_type == CHUNK_DONT_CARE:
            if payload_size != 0:
                raise SparseImageError(f"don't-care sparse chunk {chunk_index} has a payload")
            while segment_index < len(merged) and merged[segment_index][0] < logical_end:
                start, end = merged[segment_index]
                overlap_start = max(start, logical_offset)
                overlap_end = min(end, logical_end)
                if overlap_start < overlap_end:
                    output[segment_index].extend(b"\0" * (overlap_end - overlap_start))
                if end <= logical_end:
                    segment_index += 1
                else:
                    break
        elif chunk_type == CHUNK_CRC32:
            if block_count != 0 or payload_size != 4:
                raise SparseImageError(f"CRC32 sparse chunk {chunk_index} has an invalid size")
            _read_exact(stream, 4, f"CRC32 chunk {chunk_index}")
            continue
        else:
            raise SparseImageError(f"unsupported Android sparse chunk type 0x{chunk_type:04x}")

        logical_offset = logical_end

    if logical_offset != header.logical_size:
        raise SparseImageError(
            f"sparse chunks describe {logical_offset} bytes, expected {header.logical_size}"
        )
    if segment_index != len(merged):
        raise SparseImageError("sparse chunks did not supply all requested ranges")
    for request_index, segment_index, relative_offset in request_segments:
        if segment_index is None:
            continue
        requested_size = ranges[request_index][1]
        if len(output[segment_index]) < relative_offset + requested_size:
            raise SparseImageError("sparse chunks supplied a truncated requested range")

    result = [b""] * len(ranges)
    for request_index, segment_index, relative_offset in request_segments:
        if segment_index is None:
            continue
        requested_size = ranges[request_index][1]
        result[request_index] = bytes(
            output[segment_index][relative_offset : relative_offset + requested_size]
        )
    return result


@dataclass(frozen=True)
class RangeReplacement:
    """Replace `size` expanded bytes at `offset` with new data (#099, IR-680).

    The new bytes are the `source_size` bytes of `source` that start at `source_offset`, followed by
    zeros up to `size`. `source` may be None only when `source_size` is zero.
    """

    offset: int
    size: int
    source: BinaryIO | None = None
    source_offset: int = 0
    source_size: int = 0


MAX_REPLACEMENT_RAW_BLOCKS = 256


def _copy_at(stream: BinaryIO, offset: int, size: int, out: BinaryIO) -> None:
    """Copy a payload range while the chunk walk keeps its own stream position."""
    saved = stream.tell()
    try:
        stream.seek(offset)
        remaining = size
        while remaining:
            piece = _read_exact(stream, min(COPY_SIZE, remaining), "rewritten raw chunk")
            out.write(piece)
            remaining -= len(piece)
    finally:
        stream.seek(saved)


def _write_record_header(
    out: BinaryIO, chunk_type: int, block_count: int, payload_size: int
) -> None:
    """Write one 12-byte chunk header for the standard chunk layout."""
    out.write(struct.pack("<HHII", chunk_type, 0, block_count, CHUNK_HEADER_SIZE + payload_size))


def _write_kept(
    out: BinaryIO,
    stream: BinaryIO,
    chunk: SparseChunk,
    block_size: int,
    first: int,
    last: int,
) -> None:
    """Write blocks [first, last) of an input chunk as a chunk of the same type.

    The offsets are relative to the start of `chunk`.
    """
    count = last - first
    if chunk.chunk_type == CHUNK_RAW:
        _write_record_header(out, CHUNK_RAW, count, count * block_size)
        _copy_at(stream, chunk.payload_offset + first * block_size, count * block_size, out)
    elif chunk.chunk_type == CHUNK_FILL:
        if chunk.fill_pattern is None:
            raise SparseImageError("fill sparse chunk has no pattern")
        _write_record_header(out, CHUNK_FILL, count, len(chunk.fill_pattern))
        out.write(chunk.fill_pattern)
    elif chunk.chunk_type == CHUNK_DONT_CARE:
        _write_record_header(out, CHUNK_DONT_CARE, count, 0)
    else:
        raise SparseImageError(f"unsupported Android sparse chunk type 0x{chunk.chunk_type:04x}")


def _replacement_blocks(replacement: RangeReplacement, block_size: int) -> Iterator[bytes]:
    """Yield the blocks of a replacement: its source bytes, then zeros."""
    remaining = replacement.source_size
    source = replacement.source
    if source is not None and remaining:
        source.seek(replacement.source_offset)
    for _ in range(replacement.size // block_size):
        wanted = min(block_size, remaining)
        if not wanted:
            yield bytes(block_size)
            continue
        if source is None:
            raise SparseImageError("replacement has source bytes but no source")
        data = source.read(wanted)
        if len(data) != wanted:
            raise SparseImageError("replacement source is shorter than its declared size")
        remaining -= wanted
        yield data + bytes(block_size - wanted)


def _write_replacement(out: BinaryIO, replacement: RangeReplacement, block_size: int) -> int:
    """Encode a replacement's blocks: zero runs as DONT_CARE, the rest as RAW runs.

    Return the number of chunks written.
    """
    zero_block = bytes(block_size)
    chunks = 0
    run_kind: int | None = None
    run_blocks = 0
    run_payload = bytearray()

    def flush() -> int:
        if run_kind is None:
            return 0
        if run_kind == CHUNK_RAW:
            _write_record_header(out, CHUNK_RAW, run_blocks, len(run_payload))
            out.write(run_payload)
        else:
            _write_record_header(out, CHUNK_DONT_CARE, run_blocks, 0)
        return 1

    for block in _replacement_blocks(replacement, block_size):
        kind = CHUNK_DONT_CARE if block == zero_block else CHUNK_RAW
        if kind != run_kind or (kind == CHUNK_RAW and run_blocks == MAX_REPLACEMENT_RAW_BLOCKS):
            chunks += flush()
            run_kind = kind
            run_blocks = 0
            run_payload = bytearray()
        run_blocks += 1
        if kind == CHUNK_RAW:
            run_payload += block
    return chunks + flush()


def rewrite_ranges(
    stream: BinaryIO, out: BinaryIO, replacements: Sequence[RangeReplacement]
) -> int:
    """Write a sparse copy of `stream` with each replacement range replaced (#099, IR-680).

    Chunks that the replacements do not touch are written again from their parsed records, so an
    empty `replacements` gives back the input bytes. A chunk cut by a replacement keeps its type on
    both sides of the cut. `out` must be a new, empty, seekable stream. Return the chunk count.

    Only the standard 28-byte file header and 12-byte chunk headers are accepted. An image with a
    whole-image checksum or CRC32 chunks is refused, because those values would have to be
    recomputed, and so is an image with bytes after its last chunk, which a rewrite would drop.
    """
    header = read_header(stream)
    if header.file_header_size != FILE_HEADER_SIZE or header.chunk_header_size != CHUNK_HEADER_SIZE:
        raise SparseImageError("only the standard sparse header sizes can be rewritten")
    if header.image_checksum:
        raise SparseImageError("a sparse image with an image checksum cannot be rewritten")
    block_size = header.block_size

    spans: list[tuple[int, int, RangeReplacement]] = []
    for replacement in sorted(replacements, key=lambda item: item.offset):
        if replacement.offset < 0 or replacement.size <= 0:
            raise SparseImageError("replacement range must start at 0 or later and have a size")
        if not 0 <= replacement.source_size <= replacement.size:
            raise SparseImageError("replacement source size exceeds the replacement size")
        if replacement.source_size and replacement.source is None:
            raise SparseImageError("replacement has source bytes but no source")
        if replacement.offset % block_size or replacement.size % block_size:
            raise SparseImageError("replacement range is not aligned to the sparse block size")
        if replacement.offset + replacement.size > header.logical_size:
            raise SparseImageError("replacement range extends past the expanded image")
        first = replacement.offset // block_size
        last = first + replacement.size // block_size
        if spans and first < spans[-1][1]:
            raise SparseImageError("replacement ranges overlap")
        spans.append((first, last, replacement))

    out.seek(0)
    out.write(bytes(FILE_HEADER_SIZE))
    chunk_count = 0
    cursor = 0
    index = 0
    for chunk in iter_chunks(stream, header):
        if chunk.chunk_type == CHUNK_CRC32:
            raise SparseImageError("a sparse image with CRC32 chunks cannot be rewritten")
        if chunk.block_count == 0:
            raise SparseImageError("a sparse chunk with no blocks cannot be rewritten")
        first_block = chunk.logical_offset // block_size
        end_block = first_block + chunk.block_count
        if end_block <= cursor:
            continue
        cursor = max(cursor, first_block)
        while cursor < end_block:
            if index < len(spans) and spans[index][0] < cursor:
                raise SparseImageError("replacement ranges overlap")
            if index < len(spans) and spans[index][0] == cursor:
                chunk_count += _write_replacement(out, spans[index][2], block_size)
                cursor = spans[index][1]
                index += 1
                continue
            stop = end_block if index == len(spans) else min(end_block, spans[index][0])
            _write_kept(out, stream, chunk, block_size, cursor - first_block, stop - first_block)
            chunk_count += 1
            cursor = stop

    if cursor != header.total_blocks:
        raise SparseImageError("sparse chunks do not cover the declared output size")
    if stream.read(1):
        raise SparseImageError("bytes follow the last sparse chunk and cannot be rewritten")
    out.seek(0)
    out.write(
        struct.pack(
            "<I4H4I",
            SPARSE_MAGIC,
            header.major_version,
            header.minor_version,
            FILE_HEADER_SIZE,
            CHUNK_HEADER_SIZE,
            block_size,
            header.total_blocks,
            chunk_count,
            0,
        )
    )
    return chunk_count
