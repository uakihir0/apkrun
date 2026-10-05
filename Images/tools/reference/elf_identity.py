#!/usr/bin/env python3
"""Record bounded, path-free identities for host ELF files."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import struct
from pathlib import Path
from typing import BinaryIO

ELF_MAGIC = b"\x7fELF"
PT_NOTE = 4
NT_GNU_BUILD_ID = 3
MAX_PROGRAM_HEADERS = 4096
MAX_NOTE_SEGMENT_SIZE = 16 * 1024 * 1024


class InvalidELF(ValueError):
    """The file begins with ELF magic but has invalid note metadata."""


class NotELF(ValueError):
    """The file does not begin with ELF magic."""


def _read_exact(stream: BinaryIO, size: int) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise InvalidELF
    return data


def _parse_build_id(stream: BinaryIO, file_size: int) -> str | None:
    stream.seek(0)
    magic = stream.read(4)
    if magic != ELF_MAGIC:
        raise NotELF
    ident = magic + _read_exact(stream, 12)

    elf_class = ident[4]
    data_encoding = ident[5]
    if elf_class not in {1, 2} or data_encoding not in {1, 2} or ident[6] != 1:
        raise InvalidELF

    endian = "<" if data_encoding == 1 else ">"
    header_format = endian + ("HHIIIIIHHHHHH" if elf_class == 1 else "HHIQQQIHHHHHH")
    header_size = struct.calcsize(header_format)
    if 16 + header_size > file_size:
        raise InvalidELF
    header = struct.unpack(header_format, _read_exact(stream, header_size))
    if header[2] != 1:
        raise InvalidELF
    program_header_offset = header[4]
    program_header_size = header[8]
    program_header_count = header[9]

    program_header_format = endian + ("IIIIIIII" if elf_class == 1 else "IIQQQQQQ")
    minimum_program_header_size = struct.calcsize(program_header_format)
    if (
        program_header_count > MAX_PROGRAM_HEADERS
        or (program_header_count and program_header_size < minimum_program_header_size)
        or program_header_size > 4096
        or program_header_offset + program_header_size * program_header_count > file_size
    ):
        raise InvalidELF

    for index in range(program_header_count):
        stream.seek(program_header_offset + index * program_header_size)
        raw_program_header = _read_exact(stream, minimum_program_header_size)
        values = struct.unpack(program_header_format, raw_program_header)
        segment_type = values[0]
        segment_offset = values[1] if elf_class == 1 else values[2]
        segment_size = values[4] if elf_class == 1 else values[5]
        if segment_type != PT_NOTE:
            continue
        if segment_size > MAX_NOTE_SEGMENT_SIZE or segment_offset + segment_size > file_size:
            raise InvalidELF

        stream.seek(segment_offset)
        notes = _read_exact(stream, segment_size)
        cursor = 0
        while cursor < len(notes):
            remaining = len(notes) - cursor
            if remaining < 12:
                if any(notes[cursor:]):
                    raise InvalidELF
                break
            name_size, description_size, note_type = struct.unpack_from(
                endian + "III", notes, cursor
            )
            name_start = cursor + 12
            description_start = name_start + ((name_size + 3) & ~3)
            next_note = description_start + ((description_size + 3) & ~3)
            if name_start + name_size > len(notes) or next_note > len(notes):
                raise InvalidELF
            name = notes[name_start : name_start + name_size]
            description = notes[description_start : description_start + description_size]
            if name.rstrip(b"\0") == b"GNU" and note_type == NT_GNU_BUILD_ID:
                if not description or len(description) > 64:
                    raise InvalidELF
                return description.hex()
            cursor = next_note

    return None


def identify(path: Path) -> dict[str, str | None]:
    """Return the file hash and, when present, its GNU ELF Build ID."""

    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    except OSError:
        return {"status": "unavailable", "sha256": None, "elfBuildId": None}

    try:
        before = os.fstat(descriptor)
    except OSError:
        os.close(descriptor)
        return {"status": "unavailable", "sha256": None, "elfBuildId": None}
    if not stat.S_ISREG(before.st_mode):
        os.close(descriptor)
        return {"status": "unavailable", "sha256": None, "elfBuildId": None}

    try:
        with os.fdopen(descriptor, "rb") as stream:
            digest = hashlib.sha256()
            stream.seek(0)
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
            file_hash = digest.hexdigest()

            try:
                build_id = _parse_build_id(stream, before.st_size)
                status = "identified" if build_id is not None else "build_id_missing"
            except NotELF:
                build_id = None
                status = "not_elf"
            except (InvalidELF, struct.error):
                build_id = None
                status = "invalid_elf"

            after = os.fstat(stream.fileno())
            if (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            ) != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            ):
                return {"status": "changed_during_read", "sha256": None, "elfBuildId": None}
    except OSError:
        return {"status": "unavailable", "sha256": None, "elfBuildId": None}

    return {"status": status, "sha256": file_hash, "elfBuildId": build_id}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--crosvm-command", type=Path, required=True)
    parser.add_argument("--crosvm-executable", type=Path, required=True)
    parser.add_argument("--gfxstream-backend", type=Path, required=True)
    args = parser.parse_args()

    document = {
        "crosvmCommand": identify(args.crosvm_command),
        "expectedCrosvmExecutable": identify(args.crosvm_executable),
        "gfxstreamBackendCandidate": identify(args.gfxstream_backend),
    }
    print(json.dumps(document, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
