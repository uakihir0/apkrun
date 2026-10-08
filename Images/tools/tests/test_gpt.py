"""Tests for the GPT writer and reader (android-image.md §4.4)."""

from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

from apkrun_image.gpt import (
    ALIGNMENT,
    ENTRY_ARRAY_SECTORS,
    SECTOR_SIZE,
    GptError,
    GptPartition,
    disk_guid,
    encode_name,
    instance_disk_guid,
    instance_partition_guid,
    partition_guid,
    provision_disk,
    read_gpt,
    write_gpt,
)

DISK_SIZE = 4 * ALIGNMENT


def _partitions(version: str = "test") -> list[GptPartition]:
    return [
        GptPartition("misc", 2048, ALIGNMENT, partition_guid(version, "data", "misc")),
        GptPartition("userdata", 4096, ALIGNMENT, partition_guid(version, "data", "userdata")),
    ]


def _disk(partitions: list[GptPartition] | None = None) -> io.BytesIO:
    stream = io.BytesIO(bytes(DISK_SIZE))
    write_gpt(
        stream,
        disk_size=DISK_SIZE,
        guid=disk_guid("test", "data"),
        partitions=partitions if partitions is not None else _partitions(),
    )
    return stream


def test_round_trip_keeps_names_offsets_sizes_and_guids() -> None:
    table = read_gpt(_disk(), DISK_SIZE)

    assert table.disk_guid == disk_guid("test", "data")
    assert [partition.label for partition in table.partitions] == ["misc", "userdata"]
    assert [partition.first_lba for partition in table.partitions] == [2048, 4096]
    assert [partition.size for partition in table.partitions] == [ALIGNMENT, ALIGNMENT]
    assert table.partitions == tuple(_partitions())
    assert table.first_usable_lba == 2 + ENTRY_ARRAY_SECTORS
    assert table.last_usable_lba == DISK_SIZE // SECTOR_SIZE - 2 - ENTRY_ARRAY_SECTORS
    assert table.backup_lba == DISK_SIZE // SECTOR_SIZE - 1


def test_protective_mbr_and_both_headers_are_in_place() -> None:
    raw = _disk().getvalue()

    assert raw[510:512] == b"\x55\xaa"
    assert raw[450] == 0xEE
    assert raw[SECTOR_SIZE : SECTOR_SIZE + 8] == b"EFI PART"
    assert raw[DISK_SIZE - SECTOR_SIZE : DISK_SIZE - SECTOR_SIZE + 8] == b"EFI PART"


def test_guids_are_stable_uuidv5_values() -> None:
    assert partition_guid("2026.10.0", "os", "super") == uuid.UUID(
        "e5decce1-cfc4-518c-b0b8-9f208d637f2e"
    )
    assert disk_guid("2026.10.0", "os") == uuid.UUID("6a5ba8da-fd6c-5252-8a8d-e143d369dc8a")
    assert disk_guid("2026.10.0", "os").version == 5
    assert partition_guid("2026.10.0", "os", "super") != partition_guid("2026.10.1", "os", "super")


def test_writes_are_byte_identical_for_the_same_inputs() -> None:
    assert _disk().getvalue() == _disk().getvalue()


def test_names_are_utf16le_and_at_most_36_units() -> None:
    assert encode_name("boot_a")[:12] == "boot_a".encode("utf-16-le")
    assert len(encode_name("a" * 36)) == 72
    with pytest.raises(GptError, match="longer than 36"):
        encode_name("a" * 37)
    with pytest.raises(GptError, match="must not be empty"):
        encode_name("")


@pytest.mark.parametrize(
    ("partitions", "message"),
    [
        ([GptPartition("a", 2049, ALIGNMENT, uuid.uuid4())], "1 MiB boundaries"),
        ([GptPartition("a", 2048, 513, uuid.uuid4())], "multiple of 512"),
        (
            [
                GptPartition("a", 2048, 2 * ALIGNMENT, uuid.uuid4()),
                GptPartition("b", 4096, ALIGNMENT, uuid.uuid4()),
            ],
            "overlaps",
        ),
        ([GptPartition("a", 2048, 3 * ALIGNMENT, uuid.uuid4())], "last usable sector"),
        (
            [
                GptPartition("a", 2048, ALIGNMENT, uuid.uuid4()),
                GptPartition("a", 4096, ALIGNMENT, uuid.uuid4()),
            ],
            "used twice",
        ),
    ],
)
def test_invalid_layouts_are_rejected(partitions: list[GptPartition], message: str) -> None:
    with pytest.raises(GptError, match=message):
        _disk(partitions)


def test_header_crc_corruption_is_detected() -> None:
    raw = bytearray(_disk().getvalue())
    raw[SECTOR_SIZE + 24] ^= 0xFF
    with pytest.raises(GptError, match="header CRC mismatch at LBA 1"):
        read_gpt(io.BytesIO(bytes(raw)), DISK_SIZE)


def test_entry_crc_corruption_is_detected() -> None:
    raw = bytearray(_disk().getvalue())
    raw[2 * SECTOR_SIZE + 60] ^= 0xFF
    with pytest.raises(GptError, match="entry array CRC mismatch"):
        read_gpt(io.BytesIO(bytes(raw)), DISK_SIZE)


def test_a_backup_that_differs_from_the_primary_is_rejected() -> None:
    raw = bytearray(_disk().getvalue())
    backup_entries = DISK_SIZE - SECTOR_SIZE - ENTRY_ARRAY_SECTORS * SECTOR_SIZE
    raw[backup_entries + 60] ^= 0xFF
    with pytest.raises(GptError):
        read_gpt(io.BytesIO(bytes(raw)), DISK_SIZE)


def test_missing_protective_mbr_is_rejected() -> None:
    raw = bytearray(_disk().getvalue())
    raw[510:512] = b"\0\0"
    with pytest.raises(GptError, match="protective MBR"):
        read_gpt(io.BytesIO(bytes(raw)), DISK_SIZE)


@pytest.mark.skipif(
    sys.platform != "darwin" or shutil.which("hdiutil") is None,
    reason="needs macOS hdiutil (T1)",
)
def test_macos_reads_the_partition_names(tmp_path: Path) -> None:
    path = tmp_path / "disk.img"
    path.write_bytes(_disk().getvalue())
    attach = subprocess.run(
        [
            "hdiutil",
            "attach",
            "-imagekey",
            "diskimage-class=CRawDiskImage",
            "-nomount",
            "-readonly",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if attach.returncode != 0:
        pytest.skip(f"hdiutil attach is unavailable here: {attach.stderr.strip()}")
    device = attach.stdout.split()[0]
    try:
        listing = subprocess.run(
            ["diskutil", "list", device], capture_output=True, text=True, timeout=60, check=True
        ).stdout
    finally:
        subprocess.run(["hdiutil", "detach", device], capture_output=True, timeout=60, check=False)
    assert "GUID_partition_scheme" in listing
    assert listing.count("Linux Filesystem") == 2


FIXTURE_DIRECTORY = Path(__file__).parent / "fixtures/gpt"


def test_provisioning_regrows_the_last_partition_and_rewrites_guids() -> None:
    instance = uuid.UUID("3f2504e0-4f89-41d3-9a0c-0305e82c3301")
    stream = io.BytesIO(_disk().getvalue() + bytes(4 * ALIGNMENT))

    table = provision_disk(
        stream, old_size=DISK_SIZE, new_size=2 * DISK_SIZE, instance=instance, role="data"
    )

    assert table.disk_size == 2 * DISK_SIZE
    assert table.disk_guid == instance_disk_guid(instance, "data")
    assert [partition.label for partition in table.partitions] == ["misc", "userdata"]
    assert table.partitions[0].size == ALIGNMENT
    assert table.partitions[1].last_lba == table.last_usable_lba
    assert table.partitions[1].unique_guid == instance_partition_guid(instance, "data", "userdata")
    old_backup = DISK_SIZE - SECTOR_SIZE
    assert stream.getvalue()[old_backup : old_backup + 8] == bytes(8)


def test_provisioning_rejects_a_smaller_size() -> None:
    with pytest.raises(GptError, match="at least the old size"):
        provision_disk(
            _disk(),
            old_size=DISK_SIZE,
            new_size=DISK_SIZE - ALIGNMENT,
            instance=uuid.uuid4(),
            role="data",
        )


def test_the_committed_provisioning_fixture_is_current() -> None:
    sys.path.insert(0, str(FIXTURE_DIRECTORY))
    try:
        import build_gpt_fixture  # noqa: PLC0415
    finally:
        sys.path.remove(str(FIXTURE_DIRECTORY))
    committed = json.loads((FIXTURE_DIRECTORY / "provision.json").read_text(encoding="utf-8"))
    assert build_gpt_fixture.build() == committed
