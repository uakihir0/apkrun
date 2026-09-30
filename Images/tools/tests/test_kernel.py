"""Kernel decompression and arm64 Image header validation tests."""

from __future__ import annotations

import gzip
import io
import struct
import tempfile
from collections.abc import Callable
from pathlib import Path
from zipfile import ZipFile

import lz4.block
import lz4.frame
import pytest

from apkrun_image.bootimg import parse_boot_image
from apkrun_image.kernel import (
    ARM64_IMAGE_MAGIC,
    LZ4_LEGACY_BLOCK_SIZE,
    LZ4_LEGACY_MAGIC,
    KernelCompression,
    KernelImage,
    KernelImageError,
    decompress_kernel,
)

REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
PINNED_ARCHIVE = (
    REPOSITORY_ROOT / "Images/work/16373615/download/aosp_cf_arm64_only_phone-img-16373615.zip"
)


def arm64_image(
    *,
    flags: int = 10,
    text_offset: int = 0,
    image_size: int | None = None,
    extra: bytes = b"",
) -> bytes:
    """Build a minimal arm64 Image header and optional payload."""
    image = bytearray(64)
    image[56:60] = ARM64_IMAGE_MAGIC
    image.extend(extra)
    struct.pack_into(
        "<QQQ",
        image,
        8,
        text_offset,
        len(image) if image_size is None else image_size,
        flags,
    )
    return bytes(image)


def lz4_legacy_image(image: bytes, *, end_marker: bool = True) -> bytes:
    """Wrap data in Linux's size-prefixed, 8 MiB block LZ4 container."""
    encoded = bytearray(LZ4_LEGACY_MAGIC)
    for offset in range(0, len(image), LZ4_LEGACY_BLOCK_SIZE):
        block = image[offset : offset + LZ4_LEGACY_BLOCK_SIZE]
        compressed = lz4.block.compress(block, store_size=False)
        encoded.extend(struct.pack("<I", len(compressed)))
        encoded.extend(compressed)
    if end_marker:
        encoded.extend(b"\x00\x00\x00\x00")
    return bytes(encoded)


def decode(
    source_bytes: bytes,
    *,
    source_size: int | None = None,
    maximum_output_size: int = 1024 * 1024 * 1024,
) -> tuple[KernelImage, bytes]:
    """Decode a byte string through the public API using memory-backed streams."""
    output = io.BytesIO()
    metadata = decompress_kernel(
        io.BytesIO(source_bytes),
        len(source_bytes) if source_size is None else source_size,
        output,
        maximum_output_size=maximum_output_size,
    )
    return metadata, output.getvalue()


@pytest.mark.parametrize(
    ("compression", "encode"),
    (
        (KernelCompression.NONE, lambda image: image),
        (KernelCompression.GZIP, lambda image: gzip.compress(image, mtime=0)),
        (KernelCompression.LZ4_FRAME, lz4.frame.compress),
        (KernelCompression.LZ4_LEGACY, lz4_legacy_image),
    ),
)
def test_kernel_compression_formats_preserve_the_arm64_image(
    compression: KernelCompression,
    encode: Callable[[bytes], bytes],
) -> None:
    """Every documented compression format produces the original Image bytes."""
    expected = arm64_image(extra=b"kernel payload")

    metadata, output = decode(encode(expected))

    assert output == expected
    assert metadata.compression is compression
    assert metadata.size == len(expected)


def test_lz4_legacy_decodes_multiple_full_and_final_partial_blocks() -> None:
    """Legacy LZ4 uses full 8 MiB non-final blocks and permits a short final block."""
    expected = arm64_image(
        extra=(b"APKRun kernel test\x00" * (LZ4_LEGACY_BLOCK_SIZE // 19 + 1))[
            : LZ4_LEGACY_BLOCK_SIZE + 32
        ]
    )
    assert len(expected) > LZ4_LEGACY_BLOCK_SIZE

    metadata, output = decode(lz4_legacy_image(expected))

    assert output == expected
    assert metadata.compression is KernelCompression.LZ4_LEGACY


def test_lz4_legacy_accepts_eof_without_optional_zero_marker() -> None:
    """The legacy stream can end immediately after its final data block."""
    expected = arm64_image(extra=b"no marker")

    metadata, output = decode(lz4_legacy_image(expected, end_marker=False))

    assert output == expected
    assert metadata.compression is KernelCompression.LZ4_LEGACY


def test_gzip_accepts_concatenated_members() -> None:
    """Gzip member boundaries do not change the reconstructed kernel bytes."""
    expected = arm64_image(extra=b"second gzip member")
    encoded = gzip.compress(expected[:64], mtime=0) + gzip.compress(expected[64:], mtime=0)

    metadata, output = decode(encoded)

    assert output == expected
    assert metadata.compression is KernelCompression.GZIP


def test_gzip_member_ending_at_chunk_boundary_is_not_replayed() -> None:
    """A member ending at a read boundary advances to the next source chunk."""
    first_member_size = 1_048_473
    expected = arm64_image(extra=b"\x00" * (2_101_248 - 64))
    first_member = gzip.compress(
        expected[:first_member_size],
        compresslevel=0,
        mtime=0,
    )
    second_member = gzip.compress(
        expected[first_member_size:],
        compresslevel=0,
        mtime=0,
    )
    assert len(first_member) == 1024 * 1024

    metadata, output = decode(
        first_member + second_member,
        maximum_output_size=len(expected),
    )

    assert output == expected
    assert metadata.compression is KernelCompression.GZIP


def test_lz4_frame_accepts_concatenated_frames() -> None:
    """Standard LZ4 frames can be concatenated in one kernel section."""
    expected = arm64_image(extra=b"second LZ4 frame")
    encoded = lz4.frame.compress(expected[:64]) + lz4.frame.compress(expected[64:])

    metadata, output = decode(encoded)

    assert output == expected
    assert metadata.compression is KernelCompression.LZ4_FRAME


@pytest.mark.parametrize("end_marker", (False, True))
def test_lz4_legacy_accepts_concatenated_frames(end_marker: bool) -> None:
    """Legacy frame boundaries are recognized with or without zero markers."""
    expected = arm64_image(extra=b"second legacy frame")
    encoded = lz4_legacy_image(
        expected[:64],
        end_marker=end_marker,
    ) + lz4_legacy_image(expected[64:], end_marker=end_marker)

    metadata, output = decode(encoded)

    assert output == expected
    assert metadata.compression is KernelCompression.LZ4_LEGACY


@pytest.mark.parametrize(
    ("page_code", "expected_page_size"),
    ((0, None), (1, 4096), (2, 16384), (3, 65536)),
)
def test_arm64_image_header_records_page_size_flags(
    page_code: int,
    expected_page_size: int | None,
) -> None:
    """Bits 1–2 map to the documented page-size codes and preserve other flags."""
    flags = (page_code << 1) | 8
    expected = arm64_image(flags=flags)

    metadata, output = decode(expected)

    assert output == expected
    assert metadata.flags == flags
    assert metadata.page_size == expected_page_size


def test_arm64_image_header_records_text_offset_and_zero_image_size() -> None:
    """Header fields are preserved, including a valid unspecified image size."""
    expected = arm64_image(text_offset=0x80000, image_size=0)

    metadata, output = decode(expected)

    assert output == expected
    assert metadata.text_offset == 0x80000
    assert metadata.image_size == 0


def test_raw_arm64_efi_stub_prefix_is_not_mistaken_for_zboot() -> None:
    """The pinned kernel's ordinary EFI stub MZ prefix remains a raw Image."""
    expected = bytearray(arm64_image(extra=b"payload"))
    expected[:2] = b"MZ"

    metadata, output = decode(bytes(expected))

    assert output == bytes(expected)
    assert metadata.compression is KernelCompression.NONE


def test_efi_zboot_is_rejected() -> None:
    """EFI zboot is not a direct uncompressed arm64 Image."""
    payload = bytearray(arm64_image())
    payload[:2] = b"MZ"
    payload[4:8] = b"zimg"

    with pytest.raises(KernelImageError, match="EFI zboot"):
        decode(bytes(payload))


@pytest.mark.parametrize(
    ("encode", "suffix"),
    (
        (lambda image: gzip.compress(image, mtime=0), b"\x00"),
        (lz4.frame.compress, b"\x00"),
    ),
)
def test_compressed_kernel_rejects_trailing_data(
    encode: Callable[[bytes], bytes],
    suffix: bytes,
) -> None:
    """A kernel section cannot smuggle bytes after a completed compression stream."""
    with pytest.raises(KernelImageError, match="trailing data"):
        decode(encode(arm64_image()) + suffix)


@pytest.mark.parametrize(
    ("encode", "error_message"),
    (
        (lambda image: gzip.compress(image, mtime=0)[:-3], "Gzip kernel is truncated"),
        (lambda image: lz4.frame.compress(image)[:-2], "LZ4 frame kernel is truncated"),
        (
            lambda image: lz4_legacy_image(image)[:-5],
            "LZ4 legacy kernel has an invalid block size",
        ),
    ),
)
def test_truncated_compression_streams_fail_with_typed_errors(
    encode: Callable[[bytes], bytes],
    error_message: str,
) -> None:
    """Truncated gzip, LZ4 frame, and LZ4 legacy inputs never pass as kernels."""
    with pytest.raises(KernelImageError, match=error_message):
        decode(encode(arm64_image()))


def test_rejects_kernel_without_arm64_image_magic() -> None:
    """The arm64 Image magic must be present at its protocol-defined offset."""
    payload = bytearray(arm64_image())
    payload[56:60] = b"FAIL"

    with pytest.raises(KernelImageError, match=r"magic ARM\\x64 at offset 0x38"):
        decode(bytes(payload))


@pytest.mark.parametrize(
    ("flags", "message"),
    (
        (11, "Big-endian"),
        (16, "reserved flags"),
    ),
)
def test_rejects_unsupported_arm64_header_flags(flags: int, message: str) -> None:
    """Big-endian and reserved header flags are not accepted."""
    with pytest.raises(KernelImageError, match=message):
        decode(arm64_image(flags=flags))


def test_decompressed_output_limit_is_enforced() -> None:
    """Raw and compressed data cannot exceed the configured output limit."""
    expected = arm64_image(extra=b"x" * 64)

    with pytest.raises(KernelImageError, match="output limit"):
        decode(gzip.compress(expected), maximum_output_size=64)


def test_lz4_legacy_rejects_oversized_compressed_block() -> None:
    """A block length cannot exceed the fixed legacy container bound."""
    encoded = LZ4_LEGACY_MAGIC + struct.pack(
        "<I",
        LZ4_LEGACY_BLOCK_SIZE + LZ4_LEGACY_BLOCK_SIZE // 255 + 17,
    )

    with pytest.raises(KernelImageError, match="invalid block size"):
        decode(encoded)


def test_source_size_bounds_reads_and_does_not_require_seeking() -> None:
    """Only the declared kernel section is consumed from a non-seekable stream."""

    class NonSeekableReader(io.BytesIO):
        bytes_read = 0

        def seekable(self) -> bool:
            return False

        def read(self, size: int = -1) -> bytes:
            data = super().read(size)
            self.bytes_read += len(data)
            return data

        def seek(self, *args: object, **kwargs: object) -> int:
            raise OSError("seek is unavailable")

        def tell(self) -> int:
            raise OSError("tell is unavailable")

    expected = arm64_image(extra=b"bounded")
    source = NonSeekableReader(expected + b"outside section")
    output = io.BytesIO()

    metadata = decompress_kernel(source, len(expected), output)

    assert metadata.size == len(expected)
    assert output.getvalue() == expected
    assert source.bytes_read == len(expected)


def test_pinned_boot_kernel_is_uncompressed_and_has_recordable_header() -> None:
    """The selected Cuttlefish kernel works from its bounded ZIP member section."""
    if not PINNED_ARCHIVE.is_file():
        pytest.skip("pinned Cuttlefish archive is not downloaded")

    with ZipFile(PINNED_ARCHIVE) as archive:
        boot_info = archive.getinfo("boot.img")
        with archive.open("boot.img") as boot_stream:
            boot = parse_boot_image(boot_stream, boot_info.file_size, kind="boot")
            boot_stream.seek(boot.kernel.offset)
            with tempfile.TemporaryFile(mode="w+b") as kernel_output:
                metadata = decompress_kernel(
                    boot_stream,
                    boot.kernel.size,
                    kernel_output,
                )
                kernel_output.seek(0)
                prefix = kernel_output.read(4)

    assert prefix == b"MZ@\xfa"
    assert metadata.compression is KernelCompression.NONE
    assert metadata.size == boot.kernel.size == 42_031_616
    assert metadata.text_offset == 0
    assert metadata.image_size == 42_795_008
    assert metadata.flags == 10
    assert metadata.page_size == 4096


def test_decompressor_accepts_only_the_declared_bytes_from_a_seekable_source() -> None:
    """Bytes after source_size are not consumed, even when already available."""
    expected = arm64_image(extra=b"bounded")
    source = io.BytesIO(expected + b"outside section")
    output = io.BytesIO()

    metadata = decompress_kernel(source, len(expected), output)

    assert metadata.size == len(expected)
    assert source.tell() == len(expected)
    assert output.getvalue() == expected
