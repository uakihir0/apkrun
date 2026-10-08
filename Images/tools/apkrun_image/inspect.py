"""Print a human-readable summary of one Android image file."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import BinaryIO

from apkrun_image.gpt import SECTOR_SIZE, GptError, read_gpt
from apkrun_image.inventory import InventoryError, _classify


def build_parser() -> argparse.ArgumentParser:
    """Build the inspect command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image inspect",
        description="Inspect image headers and metadata without modifying the input.",
    )
    parser.add_argument("file", type=Path)
    return parser


def _gpt_summary(stream: BinaryIO, size: int) -> dict[str, object] | None:
    """Return the verified partition table of a raw GPT disk, or None for other files."""
    stream.seek(SECTOR_SIZE)
    if stream.read(8) != b"EFI PART":
        return None
    try:
        table = read_gpt(stream, size)
    except GptError as error:
        return {"error": str(error)}
    return {
        "diskGuid": str(table.disk_guid),
        "partitions": [
            {
                "firstLBA": partition.first_lba,
                "guid": str(partition.unique_guid),
                "label": partition.label,
                "lastLBA": partition.last_lba,
                "size": partition.size,
            }
            for partition in table.partitions
        ],
    }


def main(argv: Sequence[str] | None = None) -> int:
    """Inspect one file and print its content-based classification."""
    arguments = build_parser().parse_args(argv)
    path = arguments.file.expanduser()
    try:
        if not path.is_file():
            raise InventoryError(f"{path} is not a regular file.")
        size = path.stat().st_size
        with path.open("rb") as stream:
            classification = _classify(stream, size, path.name)
            gpt = _gpt_summary(stream, size)
    except (InventoryError, OSError) as error:
        print(f"apkrun_image inspect: {error}", file=sys.stderr)
        return 2

    value: dict[str, object] = {
        "details": classification.details,
        "kind": classification.kind,
        "nameMismatch": classification.name_mismatch,
        "path": path.as_posix(),
        "probablePurpose": classification.probable_purpose,
        "size": size,
    }
    if gpt is not None:
        value["gpt"] = gpt
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
