"""Build the three raw GPT disks of android-image.md §4.2 for the VZ boot spike.

Experiment only. The production writer is `apkrun_image disks` (#011). This
script reads the pinned artifacts straight from the verified download zip,
checks each member against the manifest SHA-256, and writes `os.img`,
`persistent.img`, and `userdata.img` with holes for unwritten ranges.

Usage:
    python3 -I build_disks.py --manifest <android-image.json> --zip <img zip> --out <dir>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import uuid
import zipfile
import zlib
from pathlib import Path
from typing import BinaryIO

SECTOR = 512
ALIGN = 1024 * 1024
ENTRY_COUNT = 128
ENTRY_SIZE = 128
ENTRY_SECTORS = ENTRY_COUNT * ENTRY_SIZE // SECTOR
LINUX_DATA = uuid.UUID("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
NAMESPACE = uuid.UUID("6f2c3c0e-6a52-4d1e-9a7e-61706b72756e")
COPY = 4 * 1024 * 1024

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW = 0xCAC1
CHUNK_FILL = 0xCAC2
CHUNK_DONT_CARE = 0xCAC3
CHUNK_CRC32 = 0xCAC4

# The §4.2 plan: (disk role, [(label, artifact id or None, blank size)]).
PLAN = [
    (
        "os",
        [
            ("boot_a", "boot", None),
            ("init_boot_a", "init_boot", None),
            ("vendor_boot_a", "vendor_boot", None),
            ("vbmeta_a", "vbmeta", None),
            ("vbmeta_system_a", "vbmeta_system", None),
            ("vbmeta_system_dlkm_a", "vbmeta_system_dlkm", None),
            ("vbmeta_vendor_dlkm_a", "vbmeta_vendor_dlkm", None),
            ("super", "super", None),
            ("custom", "custom", None),
        ],
    ),
    ("persistent", [("misc", None, "misc"), ("metadata", None, "metadata"), ("frp", None, "frp")]),
    ("userdata", [("userdata", None, "userdata")]),
]

# Two-disk variant: the stock fstab hands /devices/*/block/vdc to vold as
# sdcard1, so a third disk would be offered as removable storage. The writable
# partitions share one disk instead, with userdata last so it can grow.
PLAN_TWO_DISKS = [
    PLAN[0],
    (
        "instance",
        [
            ("misc", None, "misc"),
            ("metadata", None, "metadata"),
            ("frp", None, "frp"),
            ("userdata", None, "userdata"),
        ],
    ),
]


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def sparse_logical_size(stream: BinaryIO) -> int:
    header = stream.read(28)
    magic, _major, _minor, _fhs, _chs, block_size, total_blocks, _chunks, _crc = struct.unpack(
        "<IHHHHIIII", header
    )
    if magic != SPARSE_MAGIC:
        raise SystemExit("not a sparse image")
    return block_size * total_blocks


def write_sparse(stream: BinaryIO, out: BinaryIO, base: int) -> None:
    header = stream.read(28)
    magic, _major, _minor, fhs, chs, block_size, total_blocks, chunks, _crc = struct.unpack(
        "<IHHHHIIII", header
    )
    if magic != SPARSE_MAGIC:
        raise SystemExit("not a sparse image")
    stream.read(fhs - 28)
    offset = 0
    crc = 0
    for index in range(chunks):
        chunk_type, _reserved, blocks, total = struct.unpack("<HHII", stream.read(12))
        stream.read(chs - 12)
        size = blocks * block_size
        if chunk_type == CHUNK_RAW:
            out.seek(base + offset)
            remaining = size
            while remaining:
                data = stream.read(min(remaining, COPY))
                if not data:
                    raise SystemExit(f"sparse chunk {index} truncated")
                crc = zlib.crc32(data, crc)
                out.write(data)
                remaining -= len(data)
        elif chunk_type == CHUNK_FILL:
            pattern = stream.read(4)
            if pattern != b"\0\0\0\0":
                out.seek(base + offset)
                block = pattern * (COPY // 4)
                remaining = size
                while remaining:
                    piece = block[: min(remaining, COPY)]
                    crc = zlib.crc32(piece, crc)
                    out.write(piece)
                    remaining -= len(piece)
            else:
                remaining = size
                zero = b"\0" * COPY
                while remaining:
                    piece = zero[: min(remaining, COPY)]
                    crc = zlib.crc32(piece, crc)
                    remaining -= len(piece)
        elif chunk_type == CHUNK_DONT_CARE:
            remaining = size
            zero = b"\0" * COPY
            while remaining:
                piece = zero[: min(remaining, COPY)]
                crc = zlib.crc32(piece, crc)
                remaining -= len(piece)
        elif chunk_type == CHUNK_CRC32:
            expected = struct.unpack("<I", stream.read(4))[0]
            if expected != crc:
                raise SystemExit(f"sparse CRC mismatch at chunk {index}")
            continue
        else:
            raise SystemExit(f"unknown sparse chunk type {chunk_type:#x}")
        offset += size
    if offset != block_size * total_blocks:
        raise SystemExit("sparse image does not cover its declared size")


def gpt_name(label: str) -> bytes:
    encoded = label.encode("utf-16-le")
    if len(encoded) > 72:
        raise SystemExit(f"partition name too long: {label}")
    return encoded.ljust(72, b"\0")


def gpt_header(
    *,
    current: int,
    backup: int,
    first: int,
    last: int,
    disk_guid: uuid.UUID,
    entries_lba: int,
    entries_crc: int,
) -> bytes:
    fields = struct.pack(
        "<8sIIIIQQQQ16sQIII",
        b"EFI PART",
        0x00010000,
        92,
        0,
        0,
        current,
        backup,
        first,
        last,
        disk_guid.bytes_le,
        entries_lba,
        ENTRY_COUNT,
        ENTRY_SIZE,
        entries_crc,
    )
    crc = zlib.crc32(fields)
    fields = fields[:16] + struct.pack("<I", crc) + fields[20:]
    return fields.ljust(SECTOR, b"\0")


def protective_mbr(total_sectors: int) -> bytes:
    mbr = bytearray(SECTOR)
    entry = struct.pack(
        "<B3sB3sII",
        0,
        b"\x00\x02\x00",
        0xEE,
        b"\xff\xff\xff",
        1,
        min(total_sectors - 1, 0xFFFFFFFF),
    )
    mbr[446 : 446 + 16] = entry
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def write_gpt(
    out: BinaryIO, role: str, total_bytes: int, partitions: list[tuple[str, int, int]]
) -> None:
    total_sectors = total_bytes // SECTOR
    disk_guid = uuid.uuid5(NAMESPACE, f"spike/{role}")
    entries = bytearray()
    for label, start, size in partitions:
        entries += struct.pack(
            "<16s16sQQQ72s",
            LINUX_DATA.bytes_le,
            uuid.uuid5(NAMESPACE, f"spike/{role}/{label}").bytes_le,
            start // SECTOR,
            (start + size) // SECTOR - 1,
            0,
            gpt_name(label),
        )
    entries = bytes(entries.ljust(ENTRY_COUNT * ENTRY_SIZE, b"\0"))
    entries_crc = zlib.crc32(entries)
    first_usable = 2 + ENTRY_SECTORS
    last_usable = total_sectors - 2 - ENTRY_SECTORS
    backup_entries_lba = total_sectors - 1 - ENTRY_SECTORS
    out.seek(0)
    out.write(protective_mbr(total_sectors))
    out.write(
        gpt_header(
            current=1,
            backup=total_sectors - 1,
            first=first_usable,
            last=last_usable,
            disk_guid=disk_guid,
            entries_lba=2,
            entries_crc=entries_crc,
        )
    )
    out.write(entries)
    out.seek(backup_entries_lba * SECTOR)
    out.write(entries)
    out.write(
        gpt_header(
            current=total_sectors - 1,
            backup=1,
            first=first_usable,
            last=last_usable,
            disk_guid=disk_guid,
            entries_lba=backup_entries_lba,
            entries_crc=entries_crc,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--zip", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--userdata-gib", type=int, default=16)
    parser.add_argument("--two-disks", action="store_true")
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    artifacts = {item["id"]: item for item in manifest["artifacts"]}
    blanks = {item["partition"]: item["size"] for item in manifest["blankPartitions"]}
    blanks["userdata"] = args.userdata_gib * 1024 * 1024 * 1024
    args.out.mkdir(parents=True, exist_ok=True)
    record: dict[str, object] = {"disks": []}

    with zipfile.ZipFile(args.zip) as archive:
        for artifact in artifacts.values():
            digest = hashlib.sha256()
            with archive.open(artifact["file"]) as member:
                while data := member.read(COPY):
                    digest.update(data)
            if digest.hexdigest() != artifact["sha256"]:
                raise SystemExit(f"{artifact['file']}: SHA-256 mismatch")
        print("verified", len(artifacts), "artifacts", flush=True)

        for role, entries in PLAN_TWO_DISKS if args.two_disks else PLAN:
            layout = []
            cursor = ALIGN
            for label, artifact_id, blank in entries:
                if artifact_id is not None:
                    artifact = artifacts[artifact_id]
                    if artifact["kind"] == "sparse":
                        with archive.open(artifact["file"]) as member:
                            size = sparse_logical_size(member)
                    else:
                        size = artifact["size"]
                else:
                    size = blanks[blank]
                if size % SECTOR:
                    raise SystemExit(f"{label}: size {size} is not sector aligned")
                layout.append((label, artifact_id, cursor, size))
                cursor = align_up(cursor + size, ALIGN)
            total = cursor + ALIGN
            path = args.out / f"{role}.img"
            with open(path, "wb") as out:
                out.truncate(total)
                write_gpt(
                    out, role, total, [(label, start, size) for label, _, start, size in layout]
                )
                for label, artifact_id, start, size in layout:
                    if artifact_id is None:
                        continue
                    artifact = artifacts[artifact_id]
                    with archive.open(artifact["file"]) as member:
                        if artifact["kind"] == "sparse":
                            write_sparse(member, out, start)
                        else:
                            out.seek(start)
                            while data := member.read(COPY):
                                out.write(data)
                    print(f"{role}: wrote {label} ({size} bytes at {start})", flush=True)
                out.flush()
                os.fsync(out.fileno())
            record["disks"].append(
                {
                    "role": role,
                    "file": path.name,
                    "size": total,
                    "partitions": [
                        {"label": label, "source": artifact_id, "offset": start, "size": size}
                        for label, artifact_id, start, size in layout
                    ],
                }
            )
    (args.out / "disks.json").write_text(json.dumps(record, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
