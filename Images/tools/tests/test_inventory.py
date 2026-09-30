"""Content classification and determinism tests for Android build inventories."""

from __future__ import annotations

import hashlib
import io
import json
import struct
import zipfile
import zlib
from pathlib import Path
from typing import BinaryIO

import pytest

import apkrun_image.inventory as inventory_module
from apkrun_image.inventory import InventoryError, inventory, serialize_inventory
from apkrun_image.sparse import CHUNK_RAW, SPARSE_MAGIC


def boot_image(
    *,
    kernel_size: int,
    ramdisk_size: int,
    signature_size: int = 0,
) -> bytes:
    """Build a small Android boot v4 header."""
    page_size = 4096
    ramdisk_offset = (page_size + kernel_size + page_size - 1) // page_size * page_size
    ramdisk_end = ramdisk_offset + ramdisk_size
    signature_offset = (ramdisk_end + page_size - 1) // page_size * page_size
    image_size = signature_offset + signature_size
    image = bytearray(image_size)
    image[:8] = b"ANDROID!"
    struct.pack_into("<II", image, 8, kernel_size, ramdisk_size)
    os_version = (17 << 25) | ((2026 - 2000) << 4) | 9
    struct.pack_into("<I", image, 16, os_version)
    struct.pack_into("<I", image, 20, 1584)
    struct.pack_into("<I", image, 40, 4)
    struct.pack_into("<I", image, 1580, signature_size)
    image[44:60] = b"console=hvc0\0".ljust(16, b"\0")
    return bytes(image)


def avb_footer_image(
    *,
    major_version: int = 1,
    minor_version: int = 0,
    original_size: int = 4096,
    vbmeta_offset: int = 4096,
    vbmeta_size: int = 4096,
) -> bytes:
    """Build an image with an AVB footer using the format's network byte order."""
    original = bytes(4096)
    vbmeta = b"AVB0".ljust(4096, b"\0")
    footer = struct.pack(
        ">4sIIQQQ",
        b"AVBf",
        major_version,
        minor_version,
        original_size,
        vbmeta_offset,
        vbmeta_size,
    ) + bytes(28)
    return original + vbmeta + bytes(4096 - len(footer)) + footer


def vendor_boot_image() -> bytes:
    """Build a vendor boot v4 image with one platform ramdisk entry."""
    page_size = 4096
    header_size = 2128
    ramdisk = b"ram"
    dtb = b"dtb!"
    entry_size = 108
    table = bytearray(entry_size)
    struct.pack_into("<III", table, 0, len(ramdisk), 0, 1)
    table[12:44] = b"platform\0".ljust(32, b"\0")
    ramdisk_offset = page_size
    dtb_offset = ((ramdisk_offset + len(ramdisk) + page_size - 1) // page_size) * page_size
    table_offset = ((dtb_offset + len(dtb) + page_size - 1) // page_size) * page_size
    bootconfig = b"key=1"
    image = bytearray(table_offset + len(table) + len(bootconfig))
    image[:8] = b"VNDRBOOT"
    struct.pack_into("<II", image, 8, 4, page_size)
    struct.pack_into("<I", image, 24, len(ramdisk))
    image[28:40] = b"console=hvc0"
    struct.pack_into("<II", image, 2096, header_size, len(dtb))
    struct.pack_into("<Q", image, 2104, 0)
    struct.pack_into("<IIII", image, 2112, len(table), 1, entry_size, len(bootconfig))
    image[ramdisk_offset : ramdisk_offset + len(ramdisk)] = ramdisk
    image[dtb_offset : dtb_offset + len(dtb)] = dtb
    image[table_offset : table_offset + len(table)] = table
    image[table_offset + len(table) :] = bootconfig
    return bytes(image)


def vendor_boot_v3_image(*, truncate_payload: bool = False) -> bytes:
    """Build a v3 vendor boot image, optionally omitting its declared payload."""
    page_size = 4096
    header_size = 2112
    ramdisk = b"ram"
    dtb = b"dtb!"
    ramdisk_offset = page_size
    dtb_offset = page_size * 2
    image_size = header_size if truncate_payload else dtb_offset + len(dtb)
    image = bytearray(image_size)
    image[:8] = b"VNDRBOOT"
    struct.pack_into("<II", image, 8, 3, page_size)
    struct.pack_into("<I", image, 24, len(ramdisk))
    struct.pack_into("<II", image, 2096, header_size, len(dtb))
    if not truncate_payload:
        image[ramdisk_offset : ramdisk_offset + len(ramdisk)] = ramdisk
        image[dtb_offset : dtb_offset + len(dtb)] = dtb
    return bytes(image)


def vbmeta_image(
    *,
    digest_size: int = 32,
    algorithm: bytes = b"sha256",
    algorithm_type: int = 1,
) -> bytes:
    """Build a minimal vbmeta header with a hash descriptor for system_a."""
    partition_name = b"system_a"
    salt = b"salt"
    digest = bytes(digest_size)
    payload = (
        struct.pack(
            ">Q32sIIII60s",
            4096,
            algorithm,
            len(partition_name),
            len(salt),
            digest_size,
            0,
            bytes(60),
        )
        + partition_name
        + salt
        + digest
    )
    payload += bytes((-len(payload)) % 8)
    descriptor = struct.pack(">QQ", 2, len(payload)) + payload
    header = bytearray(256)
    header[:4] = b"AVB0"
    struct.pack_into(">II", header, 4, 1, 0)
    struct.pack_into(">QQ", header, 12, 0, len(descriptor))
    struct.pack_into(">I", header, 28, algorithm_type)
    struct.pack_into(">QQ", header, 96, 0, len(descriptor))
    struct.pack_into(">Q", header, 112, 23)
    struct.pack_into(">I", header, 120, 1)
    header[128:144] = b"avbtool 1.3\0".ljust(16, b"\0")
    return bytes(header) + descriptor


def ext4_image() -> bytes:
    """Build an ext4 superblock at the documented offset."""
    image = bytearray(32_768)
    struct.pack_into("<I", image, 1024 + 4, 8)
    struct.pack_into("<I", image, 1024 + 24, 2)
    struct.pack_into("<H", image, 1024 + 56, 0xEF53)
    return bytes(image)


def erofs_image() -> bytes:
    """Build a small EROFS superblock."""
    image = bytearray(4096)
    struct.pack_into("<I", image, 1024, 0xE0F5E1E2)
    image[1024 + 12] = 12
    struct.pack_into("<I", image, 1024 + 32, 7)
    struct.pack_into("<I", image, 1024 + 36, 1)
    return bytes(image)


def f2fs_image() -> bytes:
    """Build a small F2FS superblock."""
    image = bytearray(4096)
    struct.pack_into("<I", image, 1024, 0xF2F52010)
    struct.pack_into("<I", image, 1024 + 16, 12)
    struct.pack_into("<Q", image, 1024 + 36, 1)
    return bytes(image)


def liblp_super_image() -> bytes:
    """Build a minimal but checksummed super image with two geometry copies."""
    geometry = bytearray(4096)
    struct.pack_into("<II", geometry, 0, 0x616C4467, 52)
    struct.pack_into("<III", geometry, 40, 4096, 2, 4096)
    geometry[8:40] = hashlib.sha256(geometry[:52]).digest()

    device = struct.pack("<QIIQ36sI", 0, 0, 0, 2 * 1024 * 1024, b"super", 0)
    header = bytearray(128)
    struct.pack_into("<IHHI", header, 0, 0x414C5030, 10, 2, 128)
    struct.pack_into("<I", header, 44, len(device))
    header[48:80] = hashlib.sha256(device).digest()
    struct.pack_into("<III", header, 80, 0, 0, 52)
    struct.pack_into("<III", header, 92, 0, 0, 24)
    struct.pack_into("<III", header, 104, 0, 0, 48)
    struct.pack_into("<III", header, 116, 0, 1, 64)
    header[12:44] = hashlib.sha256(header).digest()

    image = bytearray(2 * 1024 * 1024)
    image[4096:8192] = geometry
    image[8192:12_288] = geometry
    image[12_288 : 12_288 + len(header) + len(device)] = header + device
    return bytes(image)


def sparse_image(expanded: bytes) -> bytes:
    """Wrap one block-aligned payload in a sparse RAW chunk."""
    block_size = 4096
    assert len(expanded) % block_size == 0
    chunk = (
        struct.pack(
            "<HHII",
            CHUNK_RAW,
            0,
            len(expanded) // block_size,
            12 + len(expanded),
        )
        + expanded
    )
    header = struct.pack(
        "<I4H4I",
        SPARSE_MAGIC,
        1,
        0,
        28,
        12,
        block_size,
        len(expanded) // block_size,
        1,
        zlib.crc32(expanded),
    )
    return header + chunk


def write_zip(path: Path, entries: dict[str, bytes]) -> None:
    """Write a timestamp-stable zip for deterministic inventory checks."""
    with zipfile.ZipFile(path, "w") as archive:
        for name, content in sorted(entries.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = (0o100644 & 0xFFFF) << 16
            archive.writestr(info, content)


def test_zip_inventory_classifies_contents_and_is_deterministic(tmp_path: Path) -> None:
    """The complete content set is retained and repeated output is byte-identical."""
    ext4 = ext4_image()
    entries = {
        "boot.img": vendor_boot_image(),
        "init_boot.img": boot_image(kernel_size=0, ramdisk_size=512),
        "android-info.txt": b"# device\nconfig=phone\ngfxstream=supported\n",
        "unknown.bin": b"\0no known image signature",
        "avb.img": vbmeta_image(),
        "filesystem.img": ext4,
        "erofs.img": erofs_image(),
        "f2fs.img": f2fs_image(),
        "linux.img": boot_image(kernel_size=1024, ramdisk_size=0),
        "super.img": sparse_image(liblp_super_image()),
        "super-filesystem.img": sparse_image(ext4),
    }
    archive_path = tmp_path / "cuttlefish.zip"
    write_zip(archive_path, entries)

    first = inventory(archive_path)
    second = inventory(archive_path)
    serialized = serialize_inventory(first)
    files = {item["path"]: item for item in first["files"]}

    assert serialized == serialize_inventory(second)
    assert first["schemaVersion"] == 2
    assert first["source"] == {
        "name": archive_path.name,
        "sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "size": archive_path.stat().st_size,
        "type": "zip",
    }
    assert [item["path"] for item in first["files"]] == sorted(entries)
    assert files["linux.img"]["details"]["bootKind"] == "boot"
    assert files["linux.img"]["details"]["osVersion"] == {
        "release": "17.0.0",
        "securityPatch": "2026-09",
    }
    assert files["init_boot.img"]["details"]["bootKind"] == "init_boot"
    assert files["boot.img"]["kind"] == "vendorBootImage"
    assert files["boot.img"]["nameMismatch"] is True
    assert files["boot.img"]["details"]["ramdisks"] == [
        {"name": "platform", "size": 3, "type": "PLATFORM"}
    ]
    assert files["avb.img"]["kind"] == "vbmeta"
    assert files["avb.img"]["details"]["descriptors"] == [{"partition": "system_a", "type": "hash"}]
    assert files["filesystem.img"]["details"] == {"size": 32_768, "type": "ext4"}
    assert files["erofs.img"]["details"] == {"size": 4096, "type": "erofs"}
    assert files["f2fs.img"]["details"] == {"size": 4096, "type": "f2fs"}
    assert files["super.img"]["kind"] == "sparse"
    assert files["super.img"]["details"]["content"]["kind"] == "dynamicPartitions"
    assert files["super-filesystem.img"]["details"]["content"]["kind"] == "filesystem"
    assert files["android-info.txt"]["details"]["values"] == {
        "config": "phone",
        "gfxstream": "supported",
    }
    assert files["unknown.bin"]["kind"] == "unknown"


def test_pinned_aosp_fixture_archive_classifies_every_generated_image() -> None:
    """The committed AOSP-generated fixtures exercise the real image parsers."""
    archive = Path(__file__).parent / "fixtures/images/aosp_cf_arm64_only_phone-img-fixture.zip"

    result = inventory(archive)
    files = {item["path"]: item for item in result["files"]}

    assert files["boot.img"]["details"]["bootKind"] == "boot"
    assert files["init_boot.img"]["details"]["bootKind"] == "init_boot"
    assert files["vendor_boot.img"]["details"]["ramdisks"] == [
        {"name": "platform", "size": 18, "type": "PLATFORM"},
        {"name": "recovery", "size": 18, "type": "RECOVERY"},
        {"name": "dlkm", "size": 14, "type": "DLKM"},
    ]
    assert files["vbmeta.img"]["details"]["descriptors"] == [
        {"partition": "system_a", "type": "chainPartition"},
        {"partition": "vendor_a", "type": "chainPartition"},
    ]
    assert files["super.img"]["details"]["content"]["kind"] == "dynamicPartitions"
    assert files["userdata.img"]["details"]["content"]["kind"] == "filesystem"
    assert files["ext4.img"]["details"]["type"] == "ext4"
    assert files["erofs.img"]["details"]["type"] == "erofs"
    assert files["f2fs.img"]["details"]["type"] == "f2fs"
    assert files["sparse-all-chunks.img"]["kind"] == "sparse"
    assert files["unknown.bin"]["kind"] == "unknown"


def test_zip_inventory_rejects_excessive_entry_count(tmp_path: Path) -> None:
    """The central-directory count is bounded before ZipFile loads its entries."""
    archive_path = tmp_path / "many-files.zip"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
        for index in range(inventory_module.MAX_ARCHIVE_ENTRIES + 1):
            archive.writestr(f"entry-{index}", b"")

    with pytest.raises(InventoryError, match="exceeds the 4096-entry limit"):
        inventory(archive_path)


def test_zip_inventory_rejects_an_underreported_entry_count(tmp_path: Path) -> None:
    """The actual central-directory records are bounded even if EOCD lies."""
    archive_path = tmp_path / "underreported-files.zip"
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_STORED) as archive:
        for index in range(inventory_module.MAX_ARCHIVE_ENTRIES + 1):
            archive.writestr(f"entry-{index}", b"")

    with archive_path.open("r+b") as stream:
        stream.seek(0, 2)
        tail_size = min(stream.tell(), 22 + 0xFFFF + 20 + 56)
        stream.seek(-tail_size, 2)
        tail = stream.read(tail_size)
        end_record = tail.rfind(b"PK\x05\x06")
        assert end_record >= 0
        stream.seek(-tail_size + end_record + 8, 2)
        stream.write(struct.pack("<HH", 1, 1))

    with pytest.raises(InventoryError, match="exceeds the 4096-entry limit"):
        inventory(archive_path)


def test_zip_central_directory_size_is_bounded_before_zipfile_loads_it() -> None:
    """The byte limit protects ZipFile from large per-entry metadata allocations."""
    end_record = struct.pack(
        "<4s4H2IH",
        b"PK\x05\x06",
        0,
        0,
        0,
        0,
        inventory_module.MAX_CENTRAL_DIRECTORY_SIZE + 1,
        0,
        0,
    )

    with pytest.raises(InventoryError, match="central directory exceeds the"):
        inventory_module._zip_entry_count(io.BytesIO(end_record), Path("large-directory.zip"))


def test_zip64_entry_count_rejects_record_overlapping_its_locator() -> None:
    """A ZIP64 record cannot claim bytes occupied by its following locator."""
    record = struct.pack(
        "<4sQ2H2I4Q",
        b"PK\x06\x06",
        60,
        45,
        45,
        0,
        0,
        0xFFFF,
        0xFFFF,
        0,
        0,
    )
    locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, 0, 1)
    end_record = struct.pack(
        "<4s4H2IH",
        b"PK\x05\x06",
        0,
        0,
        0xFFFF,
        0xFFFF,
        0,
        0,
        0,
    )
    stream = io.BytesIO(record + locator + end_record)

    with pytest.raises(InventoryError, match="zip64 directory record is truncated"):
        inventory_module._zip_entry_count(stream, Path("overlap.zip"))


def test_zip64_entry_count_rejects_extensible_data_before_zipfile() -> None:
    """CPython's fixed-size ZIP64 reader is not given extensible end records."""
    record = (
        struct.pack(
            "<4sQ2H2I4Q",
            b"PK\x06\x06",
            45,
            45,
            45,
            0,
            0,
            0xFFFF,
            0xFFFF,
            0,
            0,
        )
        + b"x"
    )
    locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, 0, 1)
    end_record = struct.pack(
        "<4s4H2IH",
        b"PK\x05\x06",
        0,
        0,
        0xFFFF,
        0xFFFF,
        0,
        0,
        0,
    )
    stream = io.BytesIO(record + locator + end_record)

    with pytest.raises(InventoryError, match="extensible data are unsupported"):
        inventory_module._zip_entry_count(stream, Path("zip64-extension.zip"))


def test_zip64_entry_count_scans_the_actual_directory() -> None:
    """A valid ZIP64 end record is cross-checked with its central directory."""
    ordinary_stream = io.BytesIO()
    with zipfile.ZipFile(ordinary_stream, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("entry.bin", b"content")
    ordinary_archive = ordinary_stream.getvalue()
    end_record_offset = ordinary_archive.rfind(b"PK\x05\x06")
    assert end_record_offset >= 0
    directory_size = struct.unpack_from("<I", ordinary_archive, end_record_offset + 12)[0]
    directory_offset = struct.unpack_from("<I", ordinary_archive, end_record_offset + 16)[0]
    zip64_offset = end_record_offset
    zip64_record = struct.pack(
        "<4sQ2H2I4Q",
        b"PK\x06\x06",
        44,
        45,
        45,
        0,
        0,
        1,
        1,
        directory_size,
        directory_offset,
    )
    locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, zip64_offset, 1)
    end_record = struct.pack(
        "<4s4H2IH",
        b"PK\x05\x06",
        0,
        0,
        0xFFFF,
        0xFFFF,
        0xFFFFFFFF,
        0xFFFFFFFF,
        0,
    )
    stream = io.BytesIO(ordinary_archive[:end_record_offset] + zip64_record + locator + end_record)

    assert inventory_module._zip_entry_count(stream, Path("zip64.zip")) == 1


def test_zip64_entry_count_handles_a_self_extracting_prefix() -> None:
    """ZIP64 offsets are relative to the archive start after an SFX prefix."""
    ordinary_stream = io.BytesIO()
    with zipfile.ZipFile(ordinary_stream, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("entry.bin", b"content")
    ordinary_archive = ordinary_stream.getvalue()
    end_record_offset = ordinary_archive.rfind(b"PK\x05\x06")
    directory_size = struct.unpack_from("<I", ordinary_archive, end_record_offset + 12)[0]
    directory_offset = struct.unpack_from("<I", ordinary_archive, end_record_offset + 16)[0]
    zip64_record = struct.pack(
        "<4sQ2H2I4Q",
        b"PK\x06\x06",
        44,
        45,
        45,
        0,
        0,
        1,
        1,
        directory_size,
        directory_offset,
    )
    locator = struct.pack("<4sIQI", b"PK\x06\x07", 0, end_record_offset, 1)
    end_record = struct.pack(
        "<4s4H2IH",
        b"PK\x05\x06",
        0,
        0,
        0xFFFF,
        0xFFFF,
        0xFFFFFFFF,
        0xFFFFFFFF,
        0,
    )
    zip64_archive = ordinary_archive[:end_record_offset] + zip64_record + locator + end_record
    prefixed_archive = b"self-extracting-prefix" + zip64_archive

    assert (
        inventory_module._zip_entry_count(
            io.BytesIO(prefixed_archive),
            Path("zip64-sfx.zip"),
        )
        == 1
    )


def test_zip_entry_limits_reject_a_declared_oversized_member() -> None:
    """A member-size claim is rejected before the decompressor is opened."""
    info = zipfile.ZipInfo("large.bin")
    info.file_size = inventory_module.MAX_MEMBER_SIZE + 1

    class FakeArchive:
        def infolist(self) -> list[zipfile.ZipInfo]:
            return [info]

    with pytest.raises(InventoryError, match="zip entry exceeds"):
        inventory_module._zip_entries(FakeArchive())  # type: ignore[arg-type]


def test_zip_entry_limits_reject_excessive_total_expansion() -> None:
    """Many individually bounded files cannot exceed the total expansion cap."""
    infos = [zipfile.ZipInfo(f"large-{index}.bin") for index in range(5)]
    for info in infos:
        info.file_size = inventory_module.MAX_MEMBER_SIZE - 1

    class FakeArchive:
        def infolist(self) -> list[zipfile.ZipInfo]:
            return infos

    with pytest.raises(InventoryError, match="expanded-size limit"):
        inventory_module._zip_entries(FakeArchive())  # type: ignore[arg-type]


def test_directory_inventory_lists_only_regular_files(tmp_path: Path) -> None:
    """Unpacked inputs use relative POSIX paths and omit directory entries."""
    root = tmp_path / "download"
    nested = root / "nested"
    nested.mkdir(parents=True)
    (nested / "metadata.txt").write_text("config=phone\n", encoding="utf-8")

    result = inventory(root)

    assert result["source"] == {"name": "download", "type": "directory"}
    assert [entry["path"] for entry in result["files"]] == ["nested/metadata.txt"]


def test_directory_inventory_rejects_a_file_replaced_by_a_symlink(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A raced symlink cannot make inventory read a file outside its input tree."""
    root = tmp_path / "download"
    root.mkdir()
    member = root / "metadata.txt"
    member.write_text("config=phone\n", encoding="utf-8")
    victim = tmp_path / "private.txt"
    victim.write_text("do not inventory this\n", encoding="utf-8")
    open_file = inventory_module._open_directory_file

    def swap_then_open(
        directory: Path,
        relative_path: str,
        path: Path,
        expected_version: tuple[int, int, int, int, int],
    ) -> BinaryIO:
        path.unlink()
        path.symlink_to(victim)
        return open_file(directory, relative_path, path, expected_version)

    monkeypatch.setattr(inventory_module, "_open_directory_file", swap_then_open)

    with pytest.raises(InventoryError, match="changed before it could be opened"):
        inventory(root)

    assert victim.read_text(encoding="utf-8") == "do not inventory this\n"


def test_directory_inventory_rejects_a_parent_directory_symlink(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A raced parent symlink cannot redirect openat outside the input tree."""
    root = tmp_path / "download"
    nested = root / "nested"
    nested.mkdir(parents=True)
    member = nested / "metadata.txt"
    member.write_text("config=phone\n", encoding="utf-8")
    private = tmp_path / "private"
    private.mkdir()
    victim = private / "metadata.txt"
    victim.write_text("secret=data!\n", encoding="utf-8")
    backup = root / "original"
    open_file = inventory_module._open_directory_file

    def swap_parent_then_open(
        directory: Path,
        relative_path: str,
        path: Path,
        expected_version: tuple[int, int, int, int, int],
    ) -> BinaryIO:
        nested.rename(backup)
        nested.symlink_to(private, target_is_directory=True)
        return open_file(directory, relative_path, path, expected_version)

    monkeypatch.setattr(inventory_module, "_open_directory_file", swap_parent_then_open)

    with pytest.raises(InventoryError, match="changed before it could be opened"):
        inventory(root)

    assert victim.read_text(encoding="utf-8") == "secret=data!\n"


def test_directory_inventory_detects_same_size_writes_between_hash_and_parse(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The inventory hash and parsed details must describe one stable file."""
    root = tmp_path / "download"
    root.mkdir()
    member = root / "metadata.txt"
    original = b"config=phone\n"
    replacement = b"config=other\n"
    member.write_bytes(original)
    initial_inode = member.stat().st_ino
    classify = inventory_module._classify

    def mutate_then_classify(
        stream: BinaryIO,
        size: int,
        path: str,
    ) -> inventory_module.Classification:
        member.write_bytes(replacement)
        return classify(stream, size, path)

    monkeypatch.setattr(inventory_module, "_classify", mutate_then_classify)

    with pytest.raises(InventoryError, match="changed during inventory"):
        inventory(root)

    assert member.stat().st_ino == initial_inode
    assert member.read_bytes() == replacement


def test_inventory_stops_when_a_stream_exceeds_its_declared_size() -> None:
    """A dishonest stream cannot force inventory to consume unbounded output."""
    entry = inventory_module.InputFile(
        path="payload",
        size=4,
        open_stream=lambda: io.BytesIO(b"12345"),
    )

    with pytest.raises(InventoryError, match="expanded beyond its declared size limit"):
        inventory_module._inventory_file(entry)


def test_download_directory_inventories_its_archive_and_provenance(tmp_path: Path) -> None:
    """A fetched download folder inventories the archive and uses its fetch metadata."""
    download = tmp_path / "download"
    download.mkdir()
    archive_name = "aosp_cf_arm64_only_phone-img-16373615.zip"
    archive = download / archive_name
    write_zip(archive, {"android-info.txt": b"config=phone\n"})
    archive_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (download / "fetch.json").write_text(
        json.dumps(
            {
                "artifacts": [
                    {
                        "name": archive_name,
                        "sha256": archive_digest,
                        "size": archive.stat().st_size,
                    }
                ],
                "branch": "aosp-android-latest-release",
                "branchProvenance": "caller-asserted",
                "buildId": "16373615",
                "schemaVersion": 2,
                "target": "aosp_cf_arm64_only_phone-userdebug",
            }
        ),
        encoding="utf-8",
    )

    result = inventory(download)

    assert result["source"] == {
        "branch": "aosp-android-latest-release",
        "branchProvenance": "caller-asserted",
        "buildId": "16373615",
        "name": archive_name,
        "sha256": archive_digest,
        "size": archive.stat().st_size,
        "target": "aosp_cf_arm64_only_phone-userdebug",
        "type": "zip",
    }
    assert [item["path"] for item in result["files"]] == ["android-info.txt"]


def test_download_directory_rejects_archive_that_differs_from_fetch_manifest(
    tmp_path: Path,
) -> None:
    """The downloaded archive must still match its recorded size and hash."""
    download = tmp_path / "download"
    download.mkdir()
    archive_name = "build.zip"
    archive = download / archive_name
    write_zip(archive, {"android-info.txt": b"config=phone\n"})
    (download / "fetch.json").write_text(
        json.dumps(
            {
                "artifacts": [
                    {"name": archive_name, "sha256": "0" * 64, "size": archive.stat().st_size}
                ],
                "branch": "branch",
                "branchProvenance": "caller-asserted",
                "buildId": "16373615",
                "schemaVersion": 2,
                "target": "target-userdebug",
            }
        ),
        encoding="utf-8",
    )

    with pytest.raises(InventoryError, match="does not match fetch.json"):
        inventory(download)


def test_inventory_rejects_archive_replaced_after_hashing(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Hash and parsing stay bound to the same archive inode."""
    download = tmp_path / "download"
    download.mkdir()
    archive_name = "build.zip"
    archive = download / archive_name
    replacement_archive = tmp_path / "replacement.zip"
    write_zip(archive, {"payload.bin": b"first payload"})
    write_zip(replacement_archive, {"payload.bin": b"other payload"})
    assert archive.stat().st_size == replacement_archive.stat().st_size
    original_digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (download / "fetch.json").write_text(
        json.dumps(
            {
                "artifacts": [
                    {
                        "name": archive_name,
                        "sha256": original_digest,
                        "size": archive.stat().st_size,
                    }
                ],
                "branch": "branch",
                "branchProvenance": "caller-asserted",
                "buildId": "16373615",
                "schemaVersion": 2,
                "target": "target-userdebug",
            }
        ),
        encoding="utf-8",
    )
    original_hash = inventory_module._hash_stream

    def hash_then_replace(
        stream: BinaryIO,
        size: int,
        path: str,
        *,
        maximum_size: int | None = None,
    ) -> str:
        digest = original_hash(stream, size, path, maximum_size=maximum_size)
        archive.write_bytes(replacement_archive.read_bytes())
        return digest

    monkeypatch.setattr(inventory_module, "_hash_stream", hash_then_replace)

    with pytest.raises(InventoryError, match="archive changed during inventory"):
        inventory(download)


def test_zip_inventory_rejects_parent_traversal(tmp_path: Path) -> None:
    """Unsafe archive paths fail rather than entering committed inventory data."""
    archive_path = tmp_path / "unsafe.zip"
    write_zip(archive_path, {"../outside.img": b"content"})

    with pytest.raises(InventoryError, match="unsafe path"):
        inventory(archive_path)


def test_truncated_boot_image_header_is_rejected(tmp_path: Path) -> None:
    """A recognizable magic prefix is insufficient for a complete boot image."""
    image = bytearray(48)
    image[:8] = b"ANDROID!"
    struct.pack_into("<I", image, 40, 4)
    archive_path = tmp_path / "truncated-boot.zip"
    write_zip(archive_path, {"boot.img": bytes(image)})

    with pytest.raises(InventoryError, match="unsupported or truncated Android boot image"):
        inventory(archive_path)


def test_boot_v4_signature_size_is_reported(tmp_path: Path) -> None:
    """A present boot signature is included in content details."""
    archive_path = tmp_path / "signed-boot.zip"
    write_zip(
        archive_path,
        {"boot.img": boot_image(kernel_size=1024, ramdisk_size=0, signature_size=4096)},
    )

    result = inventory(archive_path)["files"][0]

    assert result["kind"] == "bootImage"
    assert result["details"]["bootSignatureSize"] == 4096


def test_truncated_boot_v4_signature_is_rejected(tmp_path: Path) -> None:
    """A v4 signature size cannot extend beyond the boot image."""
    image = bytearray(boot_image(kernel_size=1024, ramdisk_size=0, signature_size=4096))
    del image[-4096:]
    archive_path = tmp_path / "truncated-boot-signature.zip"
    write_zip(archive_path, {"boot.img": bytes(image)})

    with pytest.raises(InventoryError, match="signature extends past the file size"):
        inventory(archive_path)


def test_avb_footer_is_decoded_and_bounds_checked(tmp_path: Path) -> None:
    """AVB footer integers use big-endian encoding and point inside the image."""
    archive_path = tmp_path / "avb-footer.zip"
    write_zip(archive_path, {"boot.img": avb_footer_image()})

    result = inventory(archive_path)["files"][0]

    assert result["details"]["avbFooter"] == {
        "originalSize": 4096,
        "vbmetaOffset": 4096,
        "vbmetaSize": 4096,
        "version": "1.0",
    }


@pytest.mark.parametrize(
    "footer_values",
    [
        {"major_version": 2},
        {"minor_version": 1},
        {"original_size": 8192},
        {"vbmeta_offset": 1 << 40},
        {"vbmeta_size": 0},
        {"vbmeta_size": 1 << 40},
    ],
)
def test_invalid_avb_footer_is_rejected(
    tmp_path: Path,
    footer_values: dict[str, int],
) -> None:
    """Unsupported footer versions and out-of-range values fail closed."""
    archive_path = tmp_path / "invalid-avb-footer.zip"
    write_zip(archive_path, {"boot.img": avb_footer_image(**footer_values)})

    with pytest.raises(InventoryError, match="invalid AVB footer bounds or version"):
        inventory(archive_path)


def test_vendor_boot_v3_payload_bounds_are_checked(tmp_path: Path) -> None:
    """Vendor boot v3 payloads are classified and checked against the file."""
    valid_archive = tmp_path / "valid-vendor-boot-v3.zip"
    write_zip(valid_archive, {"vendor_boot.img": vendor_boot_v3_image()})
    assert inventory(valid_archive)["files"][0]["kind"] == "vendorBootImage"

    truncated_archive = tmp_path / "truncated-vendor-boot-v3.zip"
    write_zip(
        truncated_archive,
        {"vendor_boot.img": vendor_boot_v3_image(truncate_payload=True)},
    )
    with pytest.raises(InventoryError, match="ramdisk exceeds the file size"):
        inventory(truncated_archive)


def test_vendor_boot_ramdisk_table_is_bounded(tmp_path: Path) -> None:
    """A tiny archive cannot make the parser allocate an oversized ramdisk table."""
    image = bytearray(4096)
    image[:8] = b"VNDRBOOT"
    struct.pack_into("<II", image, 8, 4, 4096)
    struct.pack_into("<II", image, 2096, 2128, 0)
    struct.pack_into("<IIII", image, 2112, 16 * 1024 * 1024 + 1, 1, 108, 0)
    archive_path = tmp_path / "oversized-vendor-boot.zip"
    write_zip(archive_path, {"vendor_boot.img": bytes(image)})

    with pytest.raises(InventoryError, match="invalid ramdisk table"):
        inventory(archive_path)


def test_invalid_avb_hash_digest_size_is_rejected(tmp_path: Path) -> None:
    """An AVB SHA-256 descriptor must carry a 32-byte digest."""
    archive_path = tmp_path / "invalid-vbmeta.zip"
    write_zip(archive_path, {"vbmeta.img": vbmeta_image(digest_size=6)})

    with pytest.raises(InventoryError, match="invalid hash algorithm or digest size"):
        inventory(archive_path)


@pytest.mark.parametrize(("algorithm_type", "name"), [(7, "MLDSA65"), (8, "MLDSA87")])
def test_avb_algorithm_names_match_pinned_aosp(
    tmp_path: Path,
    algorithm_type: int,
    name: str,
) -> None:
    """Post-quantum AVB algorithm types use the names from pinned AOSP."""
    archive_path = tmp_path / f"vbmeta-{algorithm_type}.zip"
    write_zip(archive_path, {"vbmeta.img": vbmeta_image(algorithm_type=algorithm_type)})

    files = inventory(archive_path)["files"]

    assert files[0]["details"]["algorithm"] == name


def test_avb_blake2b_256_digest_is_supported(tmp_path: Path) -> None:
    """The pinned AOSP avbtool accepts Android's blake2b-256 descriptor name."""
    archive_path = tmp_path / "blake2-vbmeta.zip"
    write_zip(archive_path, {"vbmeta.img": vbmeta_image(algorithm=b"blake2b-256")})

    files = inventory(archive_path)["files"]

    assert files[0]["details"]["descriptors"] == [{"partition": "system_a", "type": "hash"}]


def test_filesystem_larger_than_image_is_rejected(tmp_path: Path) -> None:
    """Filesystem superblocks cannot claim more bytes than the containing image."""
    archive_path = tmp_path / "truncated-ext4.zip"
    write_zip(archive_path, {"system.img": ext4_image()[:8192]})

    with pytest.raises(InventoryError, match="ext4 filesystem size extends past the image"):
        inventory(archive_path)


def test_inventory_cli_writes_requested_output(tmp_path: Path) -> None:
    """The inventory command writes deterministic JSON to --out."""
    source = tmp_path / "input"
    source.mkdir()
    (source / "info.txt").write_text("config=phone\n", encoding="utf-8")
    output = tmp_path / "manifest.json"

    from apkrun_image.inventory import main

    assert main([str(source), "--out", str(output)]) == 0
    assert json.loads(output.read_text(encoding="utf-8"))["files"][0]["path"] == "info.txt"


def test_inventory_cli_does_not_follow_output_symlink(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A symlinked --out cannot overwrite the file it points to."""
    source = tmp_path / "input"
    source.mkdir()
    (source / "info.txt").write_text("config=phone\n", encoding="utf-8")
    victim = tmp_path / "protected.json"
    victim.write_text("keep me\n", encoding="utf-8")
    output = tmp_path / "inventory.json"
    output.symlink_to(victim)

    from apkrun_image.inventory import main

    assert main([str(source), "--out", str(output)]) == 1
    assert "must not be a symbolic link" in capsys.readouterr().err
    assert victim.read_text(encoding="utf-8") == "keep me\n"


def test_inventory_cli_does_not_write_inside_input_directory(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The inventory output cannot replace or become part of its own input tree."""
    source = tmp_path / "input"
    source.mkdir()
    original = source / "info.txt"
    original.write_text("config=phone\n", encoding="utf-8")
    output = source / "new" / "nested" / "inventory.json"

    from apkrun_image.inventory import main

    assert main([str(source), "--out", str(output)]) == 1
    assert "outside the input directory" in capsys.readouterr().err
    assert not output.exists()
    assert not output.parent.exists()
    assert original.read_text(encoding="utf-8") == "config=phone\n"
