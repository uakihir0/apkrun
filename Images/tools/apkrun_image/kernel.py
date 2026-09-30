"""Decompress and inspect uncompressed arm64 Linux Image payloads."""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from enum import StrEnum
from typing import BinaryIO

import lz4.block
import lz4.frame

CHUNK_SIZE = 1024 * 1024
MAX_KERNEL_IMAGE_SIZE = 1024 * 1024 * 1024
LZ4_LEGACY_BLOCK_SIZE = 8 * 1024 * 1024
LZ4_LEGACY_BLOCK_COMPRESSED_LIMIT = LZ4_LEGACY_BLOCK_SIZE + LZ4_LEGACY_BLOCK_SIZE // 255 + 16
ARM64_IMAGE_MAGIC = b"ARM\x64"
GZIP_MAGIC = b"\x1f\x8b"
LZ4_LEGACY_MAGIC = b"\x02\x21\x4c\x18"
LZ4_FRAME_MAGIC = b"\x04\x22\x4d\x18"
LZ4_LEGACY_EOF_MARKER = b"\x00\x00\x00\x00"


class KernelImageError(Exception):
    """A kernel payload is malformed, unsupported, or exceeds a safety bound."""


class KernelCompression(StrEnum):
    """Compression detected in a boot image kernel section."""

    NONE = "none"
    GZIP = "gzip"
    LZ4_LEGACY = "lz4-legacy"
    LZ4_FRAME = "lz4-frame"


@dataclass(frozen=True)
class KernelImage:
    """Compression and arm64 Image header metadata after decompression."""

    compression: KernelCompression
    size: int
    text_offset: int
    image_size: int
    flags: int
    page_size: int | None


class _LimitedReader:
    """A bounded reader over exactly one kernel section."""

    def __init__(self, stream: BinaryIO, size: int) -> None:
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise KernelImageError("Kernel section has an invalid byte size.")
        self.stream = stream
        self.remaining = size
        self._buffer = bytearray()

    def read(self, size: int) -> bytes:
        """Read at most size bytes, handling streams that return short chunks."""
        if size < 0:
            raise KernelImageError("Kernel decoder requested an invalid read size.")
        requested = min(size, self.remaining)
        chunks = bytearray()
        buffered_size = min(requested, len(self._buffer))
        if buffered_size:
            chunks.extend(self._buffer[:buffered_size])
            del self._buffer[:buffered_size]
        while len(chunks) < requested:
            try:
                chunk = self.stream.read(requested - len(chunks))
            except (OSError, ValueError) as error:
                raise KernelImageError(f"Could not read kernel section: {error}.") from None
            if not chunk:
                break
            chunks.extend(chunk)
        self.remaining -= len(chunks)
        return bytes(chunks)

    def read_exact(self, size: int, name: str) -> bytes:
        """Read one exact field from the bounded section."""
        if size < 0 or size > self.remaining:
            raise KernelImageError(f"{name} is truncated in the kernel section.")
        value = self.read(size)
        if len(value) != size:
            raise KernelImageError(f"{name} is truncated in the kernel section.")
        return value

    def peek(self, size: int) -> bytes:
        """Inspect a prefix without requiring the source stream to support seeking."""
        if size < 0:
            raise KernelImageError("Kernel decoder requested an invalid prefix size.")
        requested = min(size, self.remaining)
        while len(self._buffer) < requested:
            try:
                chunk = self.stream.read(requested - len(self._buffer))
            except (OSError, ValueError) as error:
                raise KernelImageError(f"Could not inspect kernel section: {error}.") from None
            if not chunk:
                break
            self._buffer.extend(chunk)
        return bytes(self._buffer[:requested])


def _write_output(
    destination: BinaryIO,
    data: bytes,
    written_size: int,
    maximum_size: int,
) -> int:
    """Write output while enforcing a strict decompressed-size ceiling."""
    if len(data) > maximum_size - written_size:
        raise KernelImageError(f"Decompressed kernel exceeds the {maximum_size}-byte output limit.")
    view = memoryview(data)
    while view:
        try:
            written = destination.write(view)
        except (OSError, ValueError) as error:
            raise KernelImageError(f"Could not write decompressed kernel: {error}.") from None
        if written is None or written <= 0:
            raise KernelImageError("Could not write the complete decompressed kernel.")
        view = view[written:]
    return written_size + len(data)


def _copy_raw(
    reader: _LimitedReader,
    destination: BinaryIO,
    maximum_size: int,
) -> int:
    """Copy an uncompressed Image without buffering the entire section."""
    written_size = 0
    while chunk := reader.read(CHUNK_SIZE):
        written_size = _write_output(destination, chunk, written_size, maximum_size)
    return written_size


def _decompress_gzip(
    reader: _LimitedReader,
    destination: BinaryIO,
    maximum_size: int,
) -> int:
    """Stream concatenated gzip members to the bounded output."""
    decoder = zlib.decompressobj(wbits=31)
    written_size = 0
    pending = b""
    after_member = False
    try:
        while True:
            if not pending:
                pending = reader.read(CHUNK_SIZE)
                if not pending:
                    break
            try:
                output = decoder.decompress(
                    pending,
                    min(CHUNK_SIZE, maximum_size - written_size + 1),
                )
            except zlib.error as error:
                if after_member:
                    raise KernelImageError("Gzip kernel contains trailing data.") from None
                raise KernelImageError(f"Gzip kernel is invalid: {error}.") from None
            written_size = _write_output(
                destination,
                output,
                written_size,
                maximum_size,
            )
            if decoder.unused_data:
                after_member = False
                pending = decoder.unused_data
                decoder = zlib.decompressobj(wbits=31)
                after_member = True
                continue
            if decoder.eof:
                after_member = False
                if reader.remaining == 0:
                    break
                pending = b""
                decoder = zlib.decompressobj(wbits=31)
                after_member = True
                continue
            next_pending = decoder.unconsumed_tail
            if next_pending and not output and next_pending == pending:
                raise KernelImageError("Gzip kernel decompressor made no progress.")
            pending = next_pending
    except zlib.error as error:
        raise KernelImageError(f"Gzip kernel is invalid: {error}.") from None
    if not decoder.eof:
        if after_member:
            raise KernelImageError("Gzip kernel contains trailing data.")
        raise KernelImageError("Gzip kernel is truncated.")
    return written_size


def _decompress_lz4_frame(
    reader: _LimitedReader,
    destination: BinaryIO,
    maximum_size: int,
) -> int:
    """Stream concatenated standard LZ4 frames to the bounded output."""
    decoder = lz4.frame.LZ4FrameDecompressor()
    written_size = 0
    pending = b""
    after_frame = False
    while True:
        if not pending:
            pending = reader.read(CHUNK_SIZE)
            if not pending:
                break
        while True:
            try:
                output = decoder.decompress(
                    pending,
                    max_length=min(CHUNK_SIZE, maximum_size - written_size + 1),
                )
            except (RuntimeError, ValueError) as error:
                if after_frame:
                    raise KernelImageError("LZ4 frame kernel contains trailing data.") from None
                raise KernelImageError(f"LZ4 frame kernel is invalid: {error}.") from None
            written_size = _write_output(
                destination,
                output,
                written_size,
                maximum_size,
            )
            if decoder.unused_data:
                after_frame = False
                pending = decoder.unused_data
                decoder = lz4.frame.LZ4FrameDecompressor()
                after_frame = True
                break
            if decoder.eof:
                after_frame = False
                if reader.remaining == 0:
                    pending = b""
                    break
                decoder = lz4.frame.LZ4FrameDecompressor()
                after_frame = True
                pending = b""
                break
            if decoder.needs_input:
                pending = b""
                break
            pending = b""
        if decoder.eof and reader.remaining == 0:
            break
    if not decoder.eof:
        if after_frame:
            raise KernelImageError("LZ4 frame kernel contains trailing data.")
        raise KernelImageError("LZ4 frame kernel is truncated.")
    return written_size


def _decompress_lz4_legacy(
    reader: _LimitedReader,
    destination: BinaryIO,
    maximum_size: int,
) -> int:
    """Decode fixed-size blocks in the legacy Linux kernel LZ4 container."""
    reader.read_exact(len(LZ4_LEGACY_MAGIC), "LZ4 legacy magic")
    written_size = 0
    frame_block_count = 0
    while reader.remaining:
        compressed_size_bytes = reader.read_exact(4, "LZ4 block size")
        if compressed_size_bytes == LZ4_LEGACY_MAGIC:
            if frame_block_count == 0:
                raise KernelImageError("LZ4 legacy kernel contains an empty frame.")
            frame_block_count = 0
            if reader.remaining == 0:
                raise KernelImageError("LZ4 legacy kernel ends with an empty frame.")
            continue
        compressed_size = struct.unpack("<I", compressed_size_bytes)[0]
        if compressed_size == 0:
            if frame_block_count == 0:
                raise KernelImageError("LZ4 legacy kernel contains an empty frame.")
            if reader.remaining == 0:
                break
            if reader.peek(len(LZ4_LEGACY_MAGIC)) != LZ4_LEGACY_MAGIC:
                raise KernelImageError("LZ4 legacy kernel has an unexpected end marker.")
            reader.read_exact(len(LZ4_LEGACY_MAGIC), "LZ4 legacy magic")
            frame_block_count = 0
            if reader.remaining == 0:
                raise KernelImageError("LZ4 legacy kernel ends with an empty frame.")
            continue
        if (
            compressed_size > LZ4_LEGACY_BLOCK_COMPRESSED_LIMIT
            or compressed_size > reader.remaining
        ):
            raise KernelImageError("LZ4 legacy kernel has an invalid block size.")
        compressed = reader.read_exact(compressed_size, "LZ4 block")
        next_prefix = reader.peek(len(LZ4_LEGACY_MAGIC))
        has_linux_eof_marker = next_prefix == LZ4_LEGACY_EOF_MARKER
        has_next_frame = next_prefix == LZ4_LEGACY_MAGIC
        is_last_block = reader.remaining == 0 or has_linux_eof_marker or has_next_frame
        try:
            output = lz4.block.decompress(
                compressed,
                uncompressed_size=LZ4_LEGACY_BLOCK_SIZE,
            )
        except (lz4.block.LZ4BlockError, ValueError) as error:
            raise KernelImageError(f"LZ4 legacy kernel block is invalid: {error}.") from None
        if len(output) > LZ4_LEGACY_BLOCK_SIZE:
            raise KernelImageError("LZ4 legacy kernel block exceeds 8 MiB.")
        if len(output) < LZ4_LEGACY_BLOCK_SIZE and not is_last_block:
            raise KernelImageError("A non-final LZ4 legacy block is smaller than 8 MiB.")
        written_size = _write_output(destination, output, written_size, maximum_size)
        frame_block_count += 1
        if has_linux_eof_marker:
            reader.read_exact(len(LZ4_LEGACY_EOF_MARKER), "LZ4 legacy end marker")
            if reader.remaining:
                if reader.peek(len(LZ4_LEGACY_MAGIC)) != LZ4_LEGACY_MAGIC:
                    raise KernelImageError("LZ4 legacy kernel has trailing data.")
                reader.read_exact(len(LZ4_LEGACY_MAGIC), "LZ4 legacy magic")
                frame_block_count = 0
                if reader.remaining == 0:
                    raise KernelImageError("LZ4 legacy kernel ends with an empty frame.")
        elif has_next_frame:
            reader.read_exact(len(LZ4_LEGACY_MAGIC), "LZ4 legacy magic")
            frame_block_count = 0
            if reader.remaining == 0:
                raise KernelImageError("LZ4 legacy kernel ends with an empty frame.")
    if frame_block_count == 0:
        raise KernelImageError("LZ4 legacy kernel ends with an empty frame.")
    return written_size


def _read_image_header(
    destination: BinaryIO,
    written_size: int,
    compression: KernelCompression,
    maximum_size: int,
) -> KernelImage:
    """Validate the uncompressed arm64 Image header and record its fields."""
    if written_size < 64:
        raise KernelImageError("Decompressed kernel is shorter than the 64-byte Image header.")
    try:
        destination.flush()
        destination.seek(0)
        header = destination.read(64)
        destination.seek(written_size)
    except (OSError, ValueError) as error:
        raise KernelImageError(f"Could not inspect decompressed kernel: {error}.") from None
    if len(header) != 64 or header[56:60] != ARM64_IMAGE_MAGIC:
        raise KernelImageError(
            "Kernel payload does not have the arm64 Image magic ARM\\x64 at offset 0x38."
        )
    text_offset, image_size, flags = struct.unpack_from("<QQQ", header, 8)
    if flags & 1:
        raise KernelImageError("Big-endian arm64 kernels are not supported.")
    if flags >> 4:
        raise KernelImageError("arm64 Image header sets reserved flags.")
    page_code = (flags >> 1) & 0x3
    page_sizes = {0: None, 1: 4096, 2: 16384, 3: 65536}
    page_size = page_sizes[page_code]
    if image_size > maximum_size:
        raise KernelImageError(
            f"arm64 Image declares a size above the {maximum_size}-byte output limit."
        )
    return KernelImage(
        compression=compression,
        size=written_size,
        text_offset=text_offset,
        image_size=image_size,
        flags=flags,
        page_size=page_size,
    )


def decompress_kernel(
    source: BinaryIO,
    source_size: int,
    destination: BinaryIO,
    *,
    maximum_output_size: int = MAX_KERNEL_IMAGE_SIZE,
) -> KernelImage:
    """Decompress one kernel section and validate its arm64 Image header."""
    if (
        isinstance(maximum_output_size, bool)
        or not isinstance(maximum_output_size, int)
        or maximum_output_size <= 0
    ):
        raise KernelImageError("Kernel output limit must be a positive byte count.")
    if maximum_output_size > MAX_KERNEL_IMAGE_SIZE:
        raise KernelImageError(f"Kernel output limit cannot exceed {MAX_KERNEL_IMAGE_SIZE} bytes.")

    reader = _LimitedReader(source, source_size)
    try:
        destination.seek(0)
        destination.truncate(0)
    except (OSError, ValueError) as error:
        raise KernelImageError(f"Kernel output must be a seekable stream: {error}.") from None

    prefix = reader.peek(8)
    if prefix.startswith(GZIP_MAGIC):
        compression = KernelCompression.GZIP
        written_size = _decompress_gzip(reader, destination, maximum_output_size)
    elif prefix.startswith(LZ4_LEGACY_MAGIC):
        compression = KernelCompression.LZ4_LEGACY
        written_size = _decompress_lz4_legacy(reader, destination, maximum_output_size)
    elif prefix.startswith(LZ4_FRAME_MAGIC):
        compression = KernelCompression.LZ4_FRAME
        written_size = _decompress_lz4_frame(reader, destination, maximum_output_size)
    else:
        if len(prefix) >= 8 and prefix[:2] == b"MZ" and prefix[4:8] == b"zimg":
            raise KernelImageError("EFI zboot kernel images are not supported.")
        compression = KernelCompression.NONE
        written_size = _copy_raw(reader, destination, maximum_output_size)

    if reader.remaining:
        raise KernelImageError("Kernel decoder did not consume the complete input section.")
    return _read_image_header(destination, written_size, compression, maximum_output_size)
