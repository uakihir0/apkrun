"""GUID partition table writer and reader for 512-byte-sector raw disks.

android-image.md §4.4. The writer lays out a protective MBR, the primary
header at LBA 1, 128 entries of 128 bytes at LBA 2-33, and the backup entries
and header at the end of the disk. GUIDs are deterministic UUIDv5 values so
the same inputs give identical bytes.
"""

from __future__ import annotations

import struct
import uuid
import zlib
from collections.abc import Sequence
from dataclasses import dataclass
from typing import BinaryIO

SECTOR_SIZE = 512
ALIGNMENT = 1024 * 1024
ENTRY_COUNT = 128
ENTRY_SIZE = 128
ENTRY_ARRAY_SECTORS = ENTRY_COUNT * ENTRY_SIZE // SECTOR_SIZE
HEADER_SIZE = 92
SIGNATURE = b"EFI PART"
REVISION = 0x00010000
MAX_NAME_UNITS = 36
LINUX_FILESYSTEM_DATA = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
# Namespace of every APKRun disk and partition GUID (UUIDv5 over role and label).
GUID_NAMESPACE = uuid.UUID("5d3f0b8e-1c0a-5b0e-9d43-61706b72756e")
HEADER_FORMAT = "<8sIIIIQQQQ16sQIII"
ENTRY_FORMAT = "<16s16sQQQ72s"


class GptError(ValueError):
    """A GPT that cannot be written or does not verify."""


@dataclass(frozen=True)
class GptPartition:
    """One partition: GPT name, first sector, and size in bytes."""

    label: str
    first_lba: int
    size: int
    unique_guid: uuid.UUID
    type_guid: uuid.UUID = LINUX_FILESYSTEM_DATA

    @property
    def last_lba(self) -> int:
        """Return the inclusive last sector."""
        return self.first_lba + self.size // SECTOR_SIZE - 1


@dataclass(frozen=True)
class GptTable:
    """A verified primary GPT."""

    disk_guid: uuid.UUID
    disk_size: int
    first_usable_lba: int
    last_usable_lba: int
    backup_lba: int
    partitions: tuple[GptPartition, ...]


def disk_guid(image_version: str, role: str) -> uuid.UUID:
    """Return the deterministic disk GUID for an image version and disk role."""
    return uuid.uuid5(GUID_NAMESPACE, f"{image_version}/{role}")


def partition_guid(image_version: str, role: str, label: str) -> uuid.UUID:
    """Return the deterministic unique GUID of one partition."""
    return uuid.uuid5(GUID_NAMESPACE, f"{image_version}/{role}/{label}")


def encode_name(label: str) -> bytes:
    """Encode a partition name as 72 bytes of NUL-padded UTF-16LE."""
    if not label:
        raise GptError("partition name must not be empty.")
    encoded = label.encode("utf-16-le")
    if len(encoded) // 2 > MAX_NAME_UNITS:
        raise GptError(f"partition name {label!r} is longer than {MAX_NAME_UNITS} units.")
    return encoded.ljust(MAX_NAME_UNITS * 2, b"\0")


def first_usable_lba() -> int:
    """Return the first sector after the primary header and entry array."""
    return 2 + ENTRY_ARRAY_SECTORS


def last_usable_lba(disk_size: int) -> int:
    """Return the last sector before the backup entry array."""
    return disk_size // SECTOR_SIZE - 2 - ENTRY_ARRAY_SECTORS


def _entries(partitions: Sequence[GptPartition]) -> bytes:
    if len(partitions) > ENTRY_COUNT:
        raise GptError(f"a GPT holds at most {ENTRY_COUNT} partitions.")
    entries = bytearray()
    for partition in partitions:
        entries += struct.pack(
            ENTRY_FORMAT,
            partition.type_guid.bytes_le,
            partition.unique_guid.bytes_le,
            partition.first_lba,
            partition.last_lba,
            0,
            encode_name(partition.label),
        )
    return bytes(entries.ljust(ENTRY_COUNT * ENTRY_SIZE, b"\0"))


def _header(
    *,
    current_lba: int,
    backup_lba: int,
    first_lba: int,
    last_lba: int,
    guid: uuid.UUID,
    entries_lba: int,
    entries_crc: int,
) -> bytes:
    fields = struct.pack(
        HEADER_FORMAT,
        SIGNATURE,
        REVISION,
        HEADER_SIZE,
        0,
        0,
        current_lba,
        backup_lba,
        first_lba,
        last_lba,
        guid.bytes_le,
        entries_lba,
        ENTRY_COUNT,
        ENTRY_SIZE,
        entries_crc,
    )
    crc = zlib.crc32(fields)
    return (fields[:16] + struct.pack("<I", crc) + fields[20:]).ljust(SECTOR_SIZE, b"\0")


def _protective_mbr(total_sectors: int) -> bytes:
    mbr = bytearray(SECTOR_SIZE)
    mbr[446:462] = struct.pack(
        "<B3sB3sII",
        0,
        b"\x00\x02\x00",
        0xEE,
        b"\xff\xff\xff",
        1,
        min(total_sectors - 1, 0xFFFFFFFF),
    )
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def validate_layout(disk_size: int, partitions: Sequence[GptPartition]) -> None:
    """Check sizes, alignment, ordering, and unique names before writing."""
    if disk_size % ALIGNMENT or disk_size < 2 * ALIGNMENT:
        raise GptError("disk size must be a multiple of 1 MiB and at least 2 MiB.")
    first = first_usable_lba()
    last = last_usable_lba(disk_size)
    previous_end = first - 1
    names: set[str] = set()
    for partition in partitions:
        if partition.label in names:
            raise GptError(f"partition name {partition.label!r} is used twice.")
        names.add(partition.label)
        if partition.size <= 0 or partition.size % SECTOR_SIZE:
            raise GptError(f"{partition.label}: size must be a positive multiple of 512.")
        if (partition.first_lba * SECTOR_SIZE) % ALIGNMENT:
            raise GptError(f"{partition.label}: partitions start on 1 MiB boundaries.")
        if partition.first_lba <= previous_end:
            raise GptError(f"{partition.label}: overlaps the previous partition.")
        if partition.last_lba > last:
            raise GptError(f"{partition.label}: ends after the last usable sector.")
        previous_end = partition.last_lba


def write_gpt(
    out: BinaryIO,
    *,
    disk_size: int,
    guid: uuid.UUID,
    partitions: Sequence[GptPartition],
) -> None:
    """Write the protective MBR and both GPT copies into a disk of `disk_size` bytes."""
    validate_layout(disk_size, partitions)
    _write_tables(out, disk_size=disk_size, guid=guid, partitions=partitions)


def _write_tables(
    out: BinaryIO,
    *,
    disk_size: int,
    guid: uuid.UUID,
    partitions: Sequence[GptPartition],
) -> None:
    total_sectors = disk_size // SECTOR_SIZE
    entries = _entries(partitions)
    entries_crc = zlib.crc32(entries)
    backup_lba = total_sectors - 1
    backup_entries_lba = backup_lba - ENTRY_ARRAY_SECTORS
    common = {
        "first_lba": first_usable_lba(),
        "last_lba": last_usable_lba(disk_size),
        "guid": guid,
        "entries_crc": entries_crc,
    }
    out.seek(0)
    out.write(_protective_mbr(total_sectors))
    out.write(_header(current_lba=1, backup_lba=backup_lba, entries_lba=2, **common))
    out.write(entries)
    out.seek(backup_entries_lba * SECTOR_SIZE)
    out.write(entries)
    out.write(
        _header(
            current_lba=backup_lba,
            backup_lba=1,
            entries_lba=backup_entries_lba,
            **common,
        )
    )


def _read_exact(stream: BinaryIO, offset: int, size: int) -> bytes:
    stream.seek(offset)
    data = stream.read(size)
    if len(data) != size:
        raise GptError(f"disk is truncated at offset {offset}.")
    return data


def _parse_header(raw: bytes, *, expected_lba: int) -> tuple[tuple[object, ...], bytes]:
    fields = struct.unpack_from(HEADER_FORMAT, raw)
    if fields[0] != SIGNATURE:
        raise GptError(f"no GPT header at LBA {expected_lba}.")
    if fields[2] != HEADER_SIZE:
        raise GptError(f"unsupported GPT header size {fields[2]}.")
    header = bytearray(raw[:HEADER_SIZE])
    header[16:20] = b"\0\0\0\0"
    if zlib.crc32(header) != fields[3]:
        raise GptError(f"GPT header CRC mismatch at LBA {expected_lba}.")
    if fields[5] != expected_lba:
        raise GptError(f"GPT header at LBA {expected_lba} names LBA {fields[5]} as its own.")
    if fields[11] != ENTRY_COUNT or fields[12] != ENTRY_SIZE:
        raise GptError("unsupported GPT entry array dimensions.")
    return fields, bytes(header)


def read_gpt(stream: BinaryIO, disk_size: int) -> GptTable:
    """Read and verify the primary and backup GPT of a raw disk."""
    if disk_size % SECTOR_SIZE or disk_size < 2 * ALIGNMENT:
        raise GptError("disk size must be a multiple of 512 and at least 2 MiB.")
    mbr = _read_exact(stream, 0, SECTOR_SIZE)
    if mbr[510:512] != b"\x55\xaa" or mbr[450] != 0xEE:
        raise GptError("missing protective MBR.")
    fields, _header_bytes = _parse_header(
        _read_exact(stream, SECTOR_SIZE, SECTOR_SIZE), expected_lba=1
    )
    entries = _read_exact(stream, int(fields[10]) * SECTOR_SIZE, ENTRY_COUNT * ENTRY_SIZE)
    if zlib.crc32(entries) != fields[13]:
        raise GptError("GPT entry array CRC mismatch.")
    backup_lba = int(fields[6])
    if backup_lba != disk_size // SECTOR_SIZE - 1:
        raise GptError("the backup GPT header is not at the last sector.")
    backup, _ = _parse_header(
        _read_exact(stream, backup_lba * SECTOR_SIZE, SECTOR_SIZE), expected_lba=backup_lba
    )
    backup_entries = _read_exact(stream, int(backup[10]) * SECTOR_SIZE, ENTRY_COUNT * ENTRY_SIZE)
    if backup_entries != entries or backup[13] != fields[13] or backup[9] != fields[9]:
        raise GptError("the backup GPT does not match the primary GPT.")

    partitions: list[GptPartition] = []
    for index in range(ENTRY_COUNT):
        type_bytes, unique, first, last, _attributes, name = struct.unpack_from(
            ENTRY_FORMAT, entries, index * ENTRY_SIZE
        )
        if type_bytes == bytes(16):
            continue
        label = name.decode("utf-16-le").rstrip("\0")
        partitions.append(
            GptPartition(
                label=label,
                first_lba=first,
                size=(last - first + 1) * SECTOR_SIZE,
                unique_guid=uuid.UUID(bytes_le=unique),
                type_guid=uuid.UUID(bytes_le=type_bytes),
            )
        )
    return GptTable(
        disk_guid=uuid.UUID(bytes_le=bytes(fields[9])),
        disk_size=disk_size,
        first_usable_lba=int(fields[7]),
        last_usable_lba=int(fields[8]),
        backup_lba=backup_lba,
        partitions=tuple(partitions),
    )


def instance_disk_guid(instance: uuid.UUID, role: str) -> uuid.UUID:
    """Return the disk GUID that provisioning gives one instance's disk (§5.1)."""
    return uuid.uuid5(GUID_NAMESPACE, f"instance/{instance}/{role}")


def instance_partition_guid(instance: uuid.UUID, role: str, label: str) -> uuid.UUID:
    """Return the partition GUID that provisioning gives one instance's partition."""
    return uuid.uuid5(GUID_NAMESPACE, f"instance/{instance}/{role}/{label}")


def provision_disk(
    stream: BinaryIO,
    *,
    old_size: int,
    new_size: int,
    instance: uuid.UUID,
    role: str,
) -> GptTable:
    """Give a cloned template its instance GUIDs and grow its last partition.

    The caller has already extended the file to `new_size`. The old backup
    header and entries are zeroed, both GPT copies are rewritten for the new
    size, and the last partition ends at the new last usable sector
    (android-image.md §5.2). ImageCore's `GPTDisk` does the same in Swift; the
    fixtures in tests/fixtures/gpt/ pin both to the same bytes.
    """
    if new_size < old_size or new_size % SECTOR_SIZE:
        raise GptError("the new disk size must be at least the old size and sector aligned.")
    table = read_gpt(stream, old_size)
    if not table.partitions:
        raise GptError("the disk has no partition to grow.")
    new_last = last_usable_lba(new_size)
    partitions = [
        GptPartition(
            label=partition.label,
            first_lba=partition.first_lba,
            size=partition.size,
            unique_guid=instance_partition_guid(instance, role, partition.label),
            type_guid=partition.type_guid,
        )
        for partition in table.partitions
    ]
    last = partitions[-1]
    partitions[-1] = GptPartition(
        label=last.label,
        first_lba=last.first_lba,
        size=(new_last - last.first_lba + 1) * SECTOR_SIZE,
        unique_guid=last.unique_guid,
        type_guid=last.type_guid,
    )
    if new_size != old_size:
        old_backup_entries = (old_size // SECTOR_SIZE - 1 - ENTRY_ARRAY_SECTORS) * SECTOR_SIZE
        stream.seek(old_backup_entries)
        stream.write(bytes((ENTRY_ARRAY_SECTORS + 1) * SECTOR_SIZE))
    _write_tables(
        stream, disk_size=new_size, guid=instance_disk_guid(instance, role), partitions=partitions
    )
    return read_gpt(stream, new_size)
