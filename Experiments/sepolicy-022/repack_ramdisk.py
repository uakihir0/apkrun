"""Replace the `sepolicy` entry of an LZ4 legacy boot ramdisk, and keep every other byte (#022 experiment).

The stock ramdisk is an LZ4 legacy frame (magic 02 21 4c 18) around one or more concatenated newc
cpio archives. Only the entry named `sepolicy` changes. Its header takes the new size, and its data
and padding are rewritten. The other entries, the trailers, and the zero gaps between archives are
copied as they are. The result is compressed again with the `lz4` tool in legacy format.

Usage: python3 -B repack_ramdisk.py <stock ramdisk.img> <new sepolicy> <out ramdisk.img> <work dir>
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

LZ4_LEGACY_MAGIC = bytes.fromhex("02214c18")
NEWC_MAGIC = b"070701"
HEADER_SIZE = 110
TARGET = b"sepolicy"
LZ4_LEVEL = "-12"


def align4(value: int) -> int:
    return (value + 3) & ~3


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def decompress(path: Path) -> bytes:
    data = path.read_bytes()
    if data[:4] != LZ4_LEGACY_MAGIC:
        raise SystemExit(f"{path} is not an LZ4 legacy frame")
    return subprocess.run(["lz4", "-d", "-c", str(path)], check=True, capture_output=True).stdout


def compress(data: bytes, out: Path, work: Path) -> None:
    raw = work / "repacked.cpio"
    raw.write_bytes(data)
    subprocess.run(["lz4", "-l", LZ4_LEVEL, "-f", str(raw), str(out)], check=True)


def parse_entries(blob: bytes):
    """Yield (kind, start, end, name, header_fields) for each record of the concatenated archives.

    kind is "entry" for a newc record and "gap" for bytes between archives (zeros).
    """
    pos = 0
    while pos < len(blob):
        if blob[pos : pos + 6] != NEWC_MAGIC:
            next_magic = blob.find(NEWC_MAGIC, pos)
            if next_magic < 0:
                yield ("gap", pos, len(blob), None, None)
                return
            yield ("gap", pos, next_magic, None, None)
            pos = next_magic
            continue
        if pos % 4:
            raise SystemExit(f"newc record at offset {pos} is not 4-byte aligned")
        header = blob[pos : pos + HEADER_SIZE]
        filesize = int(header[54:62], 16)
        namesize = int(header[94:102], 16)
        name = blob[pos + HEADER_SIZE : pos + HEADER_SIZE + namesize - 1]
        data_start = align4(pos + HEADER_SIZE + namesize)
        end = align4(data_start + filesize)
        yield ("entry", pos, end, name, (header, data_start, filesize))
        pos = end


def replace_target(blob: bytes, replacement: bytes) -> tuple[bytes, dict[str, object]]:
    out = bytearray()
    report: dict[str, object] = {"entries": 0, "replaced": 0, "archives": 0}
    for kind, start, end, name, extra in parse_entries(blob):
        if kind == "gap":
            out += blob[start:end]
            continue
        report["entries"] = int(report["entries"]) + 1
        header, data_start, filesize = extra
        if name == b"TRAILER!!!":
            report["archives"] = int(report["archives"]) + 1
        if name != TARGET:
            out += blob[start:end]
            continue
        name_end = start + HEADER_SIZE + len(name) + 1
        new_header = bytearray(header)
        new_header[54:62] = f"{len(replacement):08x}".encode("ascii")
        out += new_header
        out += blob[start + HEADER_SIZE : name_end]
        out += b"\x00" * (align4(name_end) - name_end)
        out += replacement
        out += b"\x00" * (align4(len(replacement)) - len(replacement))
        report["replaced"] = int(report["replaced"]) + 1
        report["old_size"] = filesize
    return bytes(out), report


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    stock, replacement_path, out, work = (Path(a) for a in argv[1:])
    work.mkdir(parents=True, exist_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    cpio = decompress(stock)
    replacement = replacement_path.read_bytes()
    new_cpio, report = replace_target(cpio, replacement)
    if report["replaced"] != 1:
        raise SystemExit(f"expected one {TARGET!r} entry, found {report['replaced']}")
    if len(new_cpio) - len(cpio) != align4(len(replacement)) - align4(int(report["old_size"])):
        raise SystemExit("the size change is not the size of the replacement")
    (work / "repacked.cpio").write_bytes(new_cpio)
    compress(new_cpio, out, work)
    if decompress(out) != new_cpio:
        raise SystemExit("the repacked ramdisk does not decompress to the repacked cpio")
    print(f"stock cpio {len(cpio)} bytes sha256 {sha256(cpio)}")
    print(f"new cpio {len(new_cpio)} bytes sha256 {sha256(new_cpio)}")
    print(f"entries {report['entries']} archives {report['archives']} "
          f"sepolicy {report['old_size']} -> {len(replacement)} bytes")
    print(f"ramdisk {out.stat().st_size} bytes sha256 {sha256(out.read_bytes())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
