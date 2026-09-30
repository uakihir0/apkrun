"""Print a human-readable summary of one Android image file."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from apkrun_image.inventory import InventoryError, _classify


def build_parser() -> argparse.ArgumentParser:
    """Build the inspect command parser."""
    parser = argparse.ArgumentParser(
        prog="python -m apkrun_image inspect",
        description="Inspect image headers and metadata without modifying the input.",
    )
    parser.add_argument("file", type=Path)
    return parser


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
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
